use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use alsa::pcm::{Access, Format, HwParams, PCM};
use alsa::{Direction, ValueOr};

const CAPTURE_CHANNELS: u32 = 48;
const CAPTURE_RATE_HZ: u32 = 48_000;
const FRAME_MS: u32 = 20;
const FRAME_SAMPLES: usize = ((CAPTURE_RATE_HZ / 1000) * FRAME_MS) as usize;
const DEFAULT_STREAM_GROUPS: &str = "100:0-1;101:2-3";

#[derive(Debug, Clone)]
struct CaptureFrame {
    sequence: u64,
    timestamp_micros: u128,
    samples_per_channel: usize,
    source: &'static str,
    interleaved_samples: Vec<i16>,
}

#[derive(Debug, Clone)]
enum CaptureMode {
    Mock,
    Alsa { device: String },
}

#[derive(Debug, Clone)]
struct StreamGroup {
    stream_id: u16,
    channels: Vec<usize>,
}

#[derive(Debug, Clone)]
struct RuntimeConfig {
    capture_mode: CaptureMode,
    stream_groups: Vec<StreamGroup>,
    udp_targets: Vec<SocketAddr>,
    outbound_queue_depth: usize,
}

#[derive(Debug)]
struct OutboundPacket {
    bytes: Vec<u8>,
}

#[derive(Debug, Default)]
struct PipelineStats {
    capture_frames: AtomicU64,
    packets_enqueued: AtomicU64,
    packets_sent: AtomicU64,
    packets_dropped_queue_full: AtomicU64,
}

fn now_micros() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0)
}

fn capture_mode_from_env() -> CaptureMode {
    let mode = std::env::var("AUDIO_ENGINE_CAPTURE_MODE")
        .unwrap_or_else(|_| "mock".to_string())
        .to_lowercase();

    match mode.as_str() {
        "alsa" => {
            let device = std::env::var("AUDIO_ENGINE_ALSA_DEVICE")
                .unwrap_or_else(|_| "default".to_string());
            CaptureMode::Alsa { device }
        }
        _ => CaptureMode::Mock,
    }
}

fn parse_channel_expr(expr: &str) -> anyhow::Result<Vec<usize>> {
    let mut channels = Vec::new();

    for part in expr.split(',') {
        let token = part.trim();
        if token.is_empty() {
            continue;
        }

        if let Some((start, end)) = token.split_once('-') {
            let start = start.trim().parse::<usize>()?;
            let end = end.trim().parse::<usize>()?;
            if start > end {
                anyhow::bail!("invalid channel range {token}: start > end");
            }
            for ch in start..=end {
                channels.push(ch);
            }
        } else {
            channels.push(token.parse::<usize>()?);
        }
    }

    if channels.is_empty() {
        anyhow::bail!("empty channel set in expression '{expr}'");
    }

    for &ch in &channels {
        if ch >= CAPTURE_CHANNELS as usize {
            anyhow::bail!(
                "channel index {ch} is out of range for {CAPTURE_CHANNELS}-channel input"
            );
        }
    }

    Ok(channels)
}

fn stream_groups_from_env() -> anyhow::Result<Vec<StreamGroup>> {
    let raw = std::env::var("AUDIO_ENGINE_STREAM_GROUPS")
        .unwrap_or_else(|_| DEFAULT_STREAM_GROUPS.to_string());

    let mut groups = Vec::new();
    for item in raw.split(';') {
        let token = item.trim();
        if token.is_empty() {
            continue;
        }

        let (id_str, channels_str) = token
            .split_once(':')
            .ok_or_else(|| anyhow::anyhow!("invalid stream group '{token}', expected id:channels"))?;

        let stream_id = id_str.trim().parse::<u16>()?;
        let channels = parse_channel_expr(channels_str.trim())?;
        groups.push(StreamGroup {
            stream_id,
            channels,
        });
    }

    if groups.is_empty() {
        anyhow::bail!("no stream groups configured via AUDIO_ENGINE_STREAM_GROUPS");
    }

    Ok(groups)
}

fn udp_targets_from_env() -> anyhow::Result<Vec<SocketAddr>> {
    let raw = std::env::var("AUDIO_ENGINE_UDP_TARGETS").unwrap_or_default();
    if raw.trim().is_empty() {
        return Ok(Vec::new());
    }

    let mut targets = Vec::new();
    for item in raw.split(',') {
        let token = item.trim();
        if token.is_empty() {
            continue;
        }
        let addr = token.parse::<SocketAddr>()?;
        targets.push(addr);
    }

    Ok(targets)
}

fn runtime_config_from_env() -> anyhow::Result<RuntimeConfig> {
    let capture_mode = capture_mode_from_env();
    let stream_groups = stream_groups_from_env()?;
    let udp_targets = udp_targets_from_env()?;
    let outbound_queue_depth = std::env::var("AUDIO_ENGINE_OUTBOUND_QUEUE_DEPTH")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(1024);

    Ok(RuntimeConfig {
        capture_mode,
        stream_groups,
        udp_targets,
        outbound_queue_depth,
    })
}

fn spawn_capture_thread(tx: SyncSender<CaptureFrame>, mode: CaptureMode) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let result = match mode {
            CaptureMode::Mock => run_mock_capture(tx),
            CaptureMode::Alsa { device } => run_alsa_capture(tx, &device),
        };

        if let Err(err) = result {
            eprintln!("capture thread exited with error: {err}");
        }
    })
}

fn run_mock_capture(tx: SyncSender<CaptureFrame>) -> anyhow::Result<()> {
    println!("T1 capture mode: mock ({CAPTURE_CHANNELS}ch @ {CAPTURE_RATE_HZ}Hz)");

    let mut sequence = 0_u64;
    let frame_interval = Duration::from_millis(FRAME_MS as u64);

    loop {
        sequence = sequence.wrapping_add(1);
        let mut interleaved_samples = Vec::with_capacity(FRAME_SAMPLES * CAPTURE_CHANNELS as usize);
        for s in 0..FRAME_SAMPLES {
            for ch in 0..CAPTURE_CHANNELS as usize {
                interleaved_samples.push(((sequence as usize + s + ch) % 2048) as i16);
            }
        }

        tx.send(CaptureFrame {
            sequence,
            timestamp_micros: now_micros(),
            samples_per_channel: FRAME_SAMPLES,
            source: "mock",
            interleaved_samples,
        })?;
        thread::sleep(frame_interval);
    }
}

fn run_alsa_capture(tx: SyncSender<CaptureFrame>, device: &str) -> anyhow::Result<()> {
    println!("T1 capture mode: ALSA device '{device}'");

    let pcm = PCM::new(device, Direction::Capture, false)?;
    let hwp = HwParams::any(&pcm)?;
    hwp.set_channels(CAPTURE_CHANNELS)?;
    hwp.set_rate(CAPTURE_RATE_HZ, ValueOr::Nearest)?;
    hwp.set_format(Format::s16())?;
    hwp.set_access(Access::RWInterleaved)?;
    hwp.set_period_size(FRAME_SAMPLES as i64, ValueOr::Nearest)?;
    pcm.hw_params(&hwp)?;
    pcm.prepare()?;

    let io = pcm.io_i16()?;
    let mut interleaved_buf = vec![0_i16; FRAME_SAMPLES * CAPTURE_CHANNELS as usize];
    let mut sequence = 0_u64;

    loop {
        match io.readi(&mut interleaved_buf) {
            Ok(frames_read) => {
                sequence = sequence.wrapping_add(1);
                let samples_len = frames_read * CAPTURE_CHANNELS as usize;
                let interleaved_samples = interleaved_buf[..samples_len].to_vec();
                tx.send(CaptureFrame {
                    sequence,
                    timestamp_micros: now_micros(),
                    samples_per_channel: frames_read,
                    source: "alsa",
                    interleaved_samples,
                })?;
            }
            Err(err) => {
                eprintln!("ALSA capture read error: {err}. Attempting pcm.prepare()...");
                pcm.prepare()?;
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

fn split_group_interleaved(frame: &CaptureFrame, group: &StreamGroup) -> anyhow::Result<Vec<i16>> {
    let mut out = Vec::with_capacity(frame.samples_per_channel * group.channels.len());

    for sample_idx in 0..frame.samples_per_channel {
        for &ch in &group.channels {
            let src_idx = sample_idx * CAPTURE_CHANNELS as usize + ch;
            let sample = *frame
                .interleaved_samples
                .get(src_idx)
                .ok_or_else(|| anyhow::anyhow!("capture frame missing sample at index {src_idx}"))?;
            out.push(sample);
        }
    }

    Ok(out)
}

fn encode_pcm16le(interleaved_samples: &[i16]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(interleaved_samples.len() * 2);
    for &sample in interleaved_samples {
        payload.extend_from_slice(&sample.to_le_bytes());
    }
    payload
}

fn build_packet(frame: &CaptureFrame, group: &StreamGroup, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 1 + 1 + 2 + 2 + 1 + 2 + 8 + 8 + 4 + payload.len());

    out.extend_from_slice(b"BDRS");
    out.push(1);
    out.push(0);
    out.extend_from_slice(&0_u16.to_be_bytes());
    out.extend_from_slice(&group.stream_id.to_be_bytes());
    out.push(group.channels.len() as u8);
    out.extend_from_slice(&(frame.samples_per_channel as u16).to_be_bytes());
    out.extend_from_slice(&frame.sequence.to_be_bytes());
    out.extend_from_slice(&(frame.timestamp_micros as u64).to_be_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);

    out
}

fn spawn_processing_thread(
    capture_rx: Receiver<CaptureFrame>,
    outbound_tx: SyncSender<OutboundPacket>,
    stream_groups: Vec<StreamGroup>,
    stats: Arc<PipelineStats>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || loop {
        match capture_rx.recv_timeout(Duration::from_millis(200)) {
            Ok(frame) => {
                stats.capture_frames.fetch_add(1, Ordering::Relaxed);

                for group in &stream_groups {
                    let split = match split_group_interleaved(&frame, group) {
                        Ok(v) => v,
                        Err(err) => {
                            eprintln!("splitter error for stream {}: {err}", group.stream_id);
                            continue;
                        }
                    };

                    let encoded_payload = encode_pcm16le(&split);
                    let bytes = build_packet(&frame, group, &encoded_payload);
                    match outbound_tx.try_send(OutboundPacket { bytes }) {
                        Ok(()) => {
                            stats.packets_enqueued.fetch_add(1, Ordering::Relaxed);
                        }
                        Err(TrySendError::Full(_)) => {
                            stats
                                .packets_dropped_queue_full
                                .fetch_add(1, Ordering::Relaxed);
                        }
                        Err(TrySendError::Disconnected(_)) => {
                            eprintln!("outbound queue disconnected; processing thread exiting");
                            return;
                        }
                    }
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                eprintln!("capture warning: no frames received in 200ms window");
            }
            Err(RecvTimeoutError::Disconnected) => {
                eprintln!("capture thread disconnected unexpectedly");
                return;
            }
        }
    })
}

fn spawn_udp_sender_thread(
    outbound_rx: Receiver<OutboundPacket>,
    udp_targets: Vec<SocketAddr>,
    stats: Arc<PipelineStats>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        if udp_targets.is_empty() {
            eprintln!(
                "udp sender disabled: no AUDIO_ENGINE_UDP_TARGETS configured (packets will be generated but not sent)"
            );
        }

        let socket = match UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(err) => {
                eprintln!("failed to bind UDP socket: {err}");
                return;
            }
        };

        loop {
            match outbound_rx.recv_timeout(Duration::from_millis(500)) {
                Ok(packet) => {
                    if udp_targets.is_empty() {
                        continue;
                    }

                    for target in &udp_targets {
                        if let Err(err) = socket.send_to(&packet.bytes, target) {
                            eprintln!("udp send error to {target}: {err}");
                            continue;
                        }
                    }
                    stats.packets_sent.fetch_add(1, Ordering::Relaxed);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    eprintln!("outbound queue disconnected; sender thread exiting");
                    return;
                }
            }
        }
    })
}

fn main() -> anyhow::Result<()> {
    println!("Audio Engine Starting...");

    let config = runtime_config_from_env()?;
    println!(
        "runtime config: mode={:?} groups={} udp_targets={} outbound_queue_depth={}",
        config.capture_mode,
        config.stream_groups.len(),
        config.udp_targets.len(),
        config.outbound_queue_depth
    );

    let stats = Arc::new(PipelineStats::default());

    let (capture_tx, capture_rx) = sync_channel::<CaptureFrame>(512);
    let (outbound_tx, outbound_rx) = sync_channel::<OutboundPacket>(config.outbound_queue_depth);

    let _capture_handle = spawn_capture_thread(capture_tx, config.capture_mode.clone());
    let _processor_handle = spawn_processing_thread(
        capture_rx,
        outbound_tx,
        config.stream_groups.clone(),
        stats.clone(),
    );
    let _sender_handle = spawn_udp_sender_thread(outbound_rx, config.udp_targets.clone(), stats.clone());

    let mut last_log = Instant::now();

    loop {
        thread::sleep(Duration::from_millis(200));
        if last_log.elapsed() >= Duration::from_secs(2) {
            let capture_frames = stats.capture_frames.load(Ordering::Relaxed);
            let packets_enqueued = stats.packets_enqueued.load(Ordering::Relaxed);
            let packets_sent = stats.packets_sent.load(Ordering::Relaxed);
            let packets_dropped_queue_full = stats.packets_dropped_queue_full.load(Ordering::Relaxed);

            println!(
                "pipeline healthy: capture_frames={} packets_enqueued={} packets_sent={} dropped_queue_full={}",
                capture_frames, packets_enqueued, packets_sent, packets_dropped_queue_full
            );
            last_log = Instant::now();
        }
    }
}
