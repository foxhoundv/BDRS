// Runtime environment contract:
// - AUDIO_ENGINE_CAPTURE_MODE: mock|alsa (default: mock)
// - AUDIO_ENGINE_INPUT_TRANSPORT: alsa_usb|dante (default: alsa_usb)
// - AUDIO_ENGINE_ALSA_DEVICE: ALSA capture device name (default: default)
// - AUDIO_ENGINE_CAPTURE_RATE_HZ: 44100|48000 (alsa_usb), 44100|48000|96000 (dante)
// - AUDIO_ENGINE_SAMPLE_FORMAT: s16_le|s24_in_32_le (default: s24_in_32_le)
// - AUDIO_ENGINE_PAYLOAD_CODEC: pcm16|opus (default: pcm16)
// - AUDIO_ENGINE_DANTE_MAX_SOURCES: 1..64 (default: 64)
// - AUDIO_ENGINE_STREAM_GROUPS: stream mapping (default: 100:0-1;101:2-3)
// - AUDIO_ENGINE_UDP_TARGETS: comma-separated host:port UDP fanout list
// - AUDIO_ENGINE_OUTBOUND_QUEUE_DEPTH: bounded sender queue depth (default: 1024)
mod input_transport;

use std::net::{SocketAddr, UdpSocket};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use alsa::pcm::{Access, Format, HwParams, PCM};
use alsa::{Direction, ValueOr};
use input_transport::{
    build_dante_placeholder, DanteTransportConfig, DANTE_MAX_SOURCES_LIMIT,
    DANTE_SUPPORTED_SAMPLE_RATES_HZ,
};
use opus::{Application, Channels, Encoder as OpusEncoder};
use std::collections::HashMap;

const CAPTURE_CHANNELS: u32 = 48;
const FRAME_MS: u32 = 20;
const DEFAULT_CAPTURE_RATE_HZ: u32 = 48_000;
const DEFAULT_STREAM_GROUPS: &str = "100:0-1;101:2-3";

#[derive(Debug, Clone)]
struct CaptureFrame {
    sequence: u64,
    timestamp_micros: u128,
    samples_per_channel: usize,
    source: &'static str,
    interleaved_samples: Vec<i32>,
}

#[derive(Debug, Clone)]
enum CaptureMode {
    Mock,
    Alsa { device: String },
}

#[derive(Debug, Clone, Copy)]
enum InputTransport {
    AlsaUsb,
    Dante,
}

#[derive(Debug, Clone, Copy)]
enum SampleFormat {
    S16Le,
    S24In32Le,
}

#[derive(Debug, Clone, Copy)]
enum PayloadCodec {
    Pcm16,
    Opus,
}

#[derive(Debug, Clone)]
struct StreamGroup {
    stream_id: u16,
    channels: Vec<usize>,
}

#[derive(Debug, Clone)]
struct RuntimeConfig {
    capture_mode: CaptureMode,
    input_transport: InputTransport,
    capture_rate_hz: u32,
    sample_format: SampleFormat,
    payload_codec: PayloadCodec,
    dante_max_sources: u16,
    frame_samples: usize,
    test_duration_secs: Option<u64>,
    test_channel_count: usize,
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

#[derive(Debug, Clone, Default)]
struct ChannelActivity {
    total_samples: u64,
    non_zero_samples: u64,
    peak_abs: i32,
}

#[derive(Debug, Clone, Default)]
struct PacketIntegrityRow {
    packet_count: u64,
    last_sequence: Option<u64>,
    last_timestamp_micros: Option<u128>,
    sequence_gaps: u64,
    timestamp_regressions: u64,
    duplicate_sequences: u64,
}

fn now_micros() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0)
}

fn parse_first_alsa_card_device(cards_contents: &str) -> Option<String> {
    let mut fallback_device: Option<String> = None;

    for line in cards_contents.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        let idx = parts.next()?;
        if idx.chars().all(|c| c.is_ascii_digit()) {
            // Prefer plughw so ALSA can convert hardware-native formats/rates when needed.
            let device = format!("plughw:{idx},0");
            let line_lc = trimmed.to_ascii_lowercase();

            if line_lc.contains("wing") || line_lc.contains("behringer") {
                return Some(device);
            }

            if fallback_device.is_none() {
                fallback_device = Some(device);
            }
        }
    }

    fallback_device
}

fn discover_alsa_device_from_proc() -> Option<String> {
    let cards_path = Path::new("/proc/asound/cards");
    if !cards_path.exists() {
        return None;
    }

    let contents = std::fs::read_to_string(cards_path).ok()?;
    parse_first_alsa_card_device(&contents)
}

fn capture_mode_from_env() -> CaptureMode {
    let mode = std::env::var("AUDIO_ENGINE_CAPTURE_MODE")
        .unwrap_or_else(|_| "mock".to_string())
        .to_lowercase();

    match mode.as_str() {
        "alsa" => {
            let device = std::env::var("AUDIO_ENGINE_ALSA_DEVICE").unwrap_or_else(|_| {
                discover_alsa_device_from_proc().unwrap_or_else(|| "default".to_string())
            });
            CaptureMode::Alsa { device }
        }
        _ => CaptureMode::Mock,
    }
}

fn input_transport_from_env() -> anyhow::Result<InputTransport> {
    let raw = std::env::var("AUDIO_ENGINE_INPUT_TRANSPORT")
        .unwrap_or_else(|_| "alsa_usb".to_string())
        .to_lowercase();

    match raw.as_str() {
        "alsa_usb" => Ok(InputTransport::AlsaUsb),
        "dante" => Ok(InputTransport::Dante),
        _ => anyhow::bail!(
            "unsupported AUDIO_ENGINE_INPUT_TRANSPORT='{raw}'. Supported values: alsa_usb, dante"
        ),
    }
}

fn capture_rate_from_env(input_transport: InputTransport) -> anyhow::Result<u32> {
    let raw = std::env::var("AUDIO_ENGINE_CAPTURE_RATE_HZ")
        .unwrap_or_else(|_| DEFAULT_CAPTURE_RATE_HZ.to_string());
    let rate = raw.parse::<u32>().map_err(|_| {
        anyhow::anyhow!(
            "AUDIO_ENGINE_CAPTURE_RATE_HZ must be an integer"
        )
    })?;

    let supported = match input_transport {
        InputTransport::AlsaUsb => &[44_100_u32, 48_000_u32][..],
        InputTransport::Dante => &DANTE_SUPPORTED_SAMPLE_RATES_HZ,
    };

    if supported.contains(&rate) {
        Ok(rate)
    } else {
        let supported_text = supported
            .iter()
            .map(|r| r.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        anyhow::bail!(
            "unsupported AUDIO_ENGINE_CAPTURE_RATE_HZ={rate} for transport {:?}. Supported values: {supported_text}",
            input_transport
        )
    }
}

fn capture_sample_format_from_env() -> anyhow::Result<SampleFormat> {
    let raw = std::env::var("AUDIO_ENGINE_SAMPLE_FORMAT")
        .unwrap_or_else(|_| "s24_in_32_le".to_string())
        .to_lowercase();

    match raw.as_str() {
        "s16_le" => Ok(SampleFormat::S16Le),
        "s24_in_32_le" => Ok(SampleFormat::S24In32Le),
        _ => anyhow::bail!(
            "unsupported AUDIO_ENGINE_SAMPLE_FORMAT='{raw}'. Supported values: s16_le, s24_in_32_le"
        ),
    }
}

fn dante_max_sources_from_env() -> anyhow::Result<u16> {
    let raw = std::env::var("AUDIO_ENGINE_DANTE_MAX_SOURCES")
        .unwrap_or_else(|_| DANTE_MAX_SOURCES_LIMIT.to_string());
    let value = raw.parse::<u16>().map_err(|_| {
        anyhow::anyhow!(
            "AUDIO_ENGINE_DANTE_MAX_SOURCES must be an integer in range 1..={}",
            DANTE_MAX_SOURCES_LIMIT
        )
    })?;

    if value == 0 || value > DANTE_MAX_SOURCES_LIMIT {
        anyhow::bail!(
            "AUDIO_ENGINE_DANTE_MAX_SOURCES={} is out of range. Allowed: 1..={}",
            value,
            DANTE_MAX_SOURCES_LIMIT
        );
    }

    Ok(value)
}

fn payload_codec_from_env() -> anyhow::Result<PayloadCodec> {
    let raw = std::env::var("AUDIO_ENGINE_PAYLOAD_CODEC")
        .unwrap_or_else(|_| "pcm16".to_string())
        .to_lowercase();

    match raw.as_str() {
        "pcm16" => Ok(PayloadCodec::Pcm16),
        "opus" => Ok(PayloadCodec::Opus),
        _ => anyhow::bail!(
            "unsupported AUDIO_ENGINE_PAYLOAD_CODEC='{raw}'. Supported values: pcm16, opus"
        ),
    }
}

fn test_duration_secs_from_env() -> anyhow::Result<Option<u64>> {
    let raw = std::env::var("AUDIO_ENGINE_TEST_DURATION_SECS").ok();
    let Some(raw) = raw else {
        return Ok(None);
    };

    let value = raw.parse::<u64>().map_err(|_| {
        anyhow::anyhow!("AUDIO_ENGINE_TEST_DURATION_SECS must be an integer number of seconds")
    })?;

    if value == 0 {
        return Ok(None);
    }

    Ok(Some(value))
}

fn test_channel_count_from_env() -> anyhow::Result<usize> {
    let raw = std::env::var("AUDIO_ENGINE_TEST_CHANNEL_COUNT").unwrap_or_else(|_| "16".to_string());
    let value = raw
        .parse::<usize>()
        .map_err(|_| anyhow::anyhow!("AUDIO_ENGINE_TEST_CHANNEL_COUNT must be an integer"))?;

    if value == 0 || value > CAPTURE_CHANNELS as usize {
        anyhow::bail!(
            "AUDIO_ENGINE_TEST_CHANNEL_COUNT={} is out of range. Allowed: 1..={}",
            value,
            CAPTURE_CHANNELS
        );
    }

    Ok(value)
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
    let input_transport = input_transport_from_env()?;
    let capture_rate_hz = capture_rate_from_env(input_transport)?;
    let sample_format = capture_sample_format_from_env()?;
    let payload_codec = payload_codec_from_env()?;
    let dante_max_sources = dante_max_sources_from_env()?;
    let frame_samples = ((capture_rate_hz / 1000) * FRAME_MS) as usize;
    let test_duration_secs = test_duration_secs_from_env()?;
    let test_channel_count = test_channel_count_from_env()?;
    let stream_groups = stream_groups_from_env().map_err(|err| {
        anyhow::anyhow!(
            "invalid AUDIO_ENGINE_STREAM_GROUPS: {err}. Example valid value: 100:0-1;101:2-3"
        )
    })?;
    let udp_targets = udp_targets_from_env()?;
    let outbound_queue_depth = std::env::var("AUDIO_ENGINE_OUTBOUND_QUEUE_DEPTH")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(1024);

    if matches!(payload_codec, PayloadCodec::Opus) && capture_rate_hz != 48_000 {
        anyhow::bail!(
            "AUDIO_ENGINE_PAYLOAD_CODEC=opus currently requires AUDIO_ENGINE_CAPTURE_RATE_HZ=48000 (got {capture_rate_hz})"
        );
    }

    Ok(RuntimeConfig {
        capture_mode,
        input_transport,
        capture_rate_hz,
        sample_format,
        payload_codec,
        dante_max_sources,
        frame_samples,
        test_duration_secs,
        test_channel_count,
        stream_groups,
        udp_targets,
        outbound_queue_depth,
    })
}

fn update_channel_activity(
    frame: &CaptureFrame,
    channels: usize,
    activity: &Arc<Mutex<Vec<ChannelActivity>>>,
) {
    let mut guard = match activity.lock() {
        Ok(g) => g,
        Err(_) => return,
    };

    for sample_idx in 0..frame.samples_per_channel {
        for ch in 0..channels {
            let idx = sample_idx * CAPTURE_CHANNELS as usize + ch;
            let Some(&sample) = frame.interleaved_samples.get(idx) else {
                continue;
            };

            let row = &mut guard[ch];
            row.total_samples = row.total_samples.saturating_add(1);
            if sample != 0 {
                row.non_zero_samples = row.non_zero_samples.saturating_add(1);
            }

            let abs = sample.saturating_abs();
            if abs > row.peak_abs {
                row.peak_abs = abs;
            }
        }
    }
}

fn print_channel_activity_summary(activity: &Arc<Mutex<Vec<ChannelActivity>>>) {
    let guard = match activity.lock() {
        Ok(g) => g,
        Err(_) => {
            eprintln!("test summary unavailable: channel activity lock poisoned");
            return;
        }
    };

    println!("--- Source Activity Summary ---");
    for (i, row) in guard.iter().enumerate() {
        let pct = if row.total_samples == 0 {
            0.0
        } else {
            (row.non_zero_samples as f64 / row.total_samples as f64) * 100.0
        };
        let status = if row.non_zero_samples > 0 { "ACTIVE" } else { "SILENT" };
        println!(
            "source_ch={} status={} non_zero_pct={:.2}% peak_abs={}",
            i + 1,
            status,
            pct,
            row.peak_abs
        );
    }
    println!("--- End Source Activity Summary ---");
}

fn update_packet_integrity(
    integrity: &Arc<Mutex<HashMap<u16, PacketIntegrityRow>>>,
    stream_id: u16,
    sequence: u64,
    timestamp_micros: u128,
) {
    let mut guard = match integrity.lock() {
        Ok(g) => g,
        Err(_) => return,
    };

    let row = guard.entry(stream_id).or_default();
    row.packet_count = row.packet_count.saturating_add(1);

    if let Some(last_sequence) = row.last_sequence {
        if sequence == last_sequence {
            row.duplicate_sequences = row.duplicate_sequences.saturating_add(1);
        } else if sequence > last_sequence + 1 {
            row.sequence_gaps = row.sequence_gaps.saturating_add(sequence - last_sequence - 1);
        }
    }

    if let Some(last_timestamp_micros) = row.last_timestamp_micros {
        if timestamp_micros < last_timestamp_micros {
            row.timestamp_regressions = row.timestamp_regressions.saturating_add(1);
        }
    }

    row.last_sequence = Some(sequence);
    row.last_timestamp_micros = Some(timestamp_micros);
}

fn print_packet_integrity_summary(integrity: &Arc<Mutex<HashMap<u16, PacketIntegrityRow>>>) {
    let guard = match integrity.lock() {
        Ok(g) => g,
        Err(_) => {
            eprintln!("test summary unavailable: packet integrity lock poisoned");
            return;
        }
    };

    println!("--- Packet Integrity Summary ---");
    let mut stream_ids = guard.keys().copied().collect::<Vec<_>>();
    stream_ids.sort_unstable();

    for stream_id in stream_ids {
        if let Some(row) = guard.get(&stream_id) {
            println!(
                "stream_id={} packets={} sequence_gaps={} duplicate_sequences={} timestamp_regressions={}",
                stream_id,
                row.packet_count,
                row.sequence_gaps,
                row.duplicate_sequences,
                row.timestamp_regressions
            );
        }
    }
    println!("--- End Packet Integrity Summary ---");
}

fn spawn_capture_thread(
    tx: SyncSender<CaptureFrame>,
    mode: CaptureMode,
    capture_rate_hz: u32,
    frame_samples: usize,
    sample_format: SampleFormat,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let result = match mode {
            CaptureMode::Mock => run_mock_capture(tx, capture_rate_hz, frame_samples),
            CaptureMode::Alsa { device } => {
                run_alsa_capture(tx, &device, capture_rate_hz, frame_samples, sample_format)
            }
        };

        if let Err(err) = result {
            eprintln!("capture thread exited with error: {err}");
        }
    })
}

fn run_mock_capture(
    tx: SyncSender<CaptureFrame>,
    capture_rate_hz: u32,
    frame_samples: usize,
) -> anyhow::Result<()> {
    println!("T1 capture mode: mock ({CAPTURE_CHANNELS}ch @ {capture_rate_hz}Hz)");

    let mut sequence = 0_u64;
    let frame_interval = Duration::from_millis(FRAME_MS as u64);

    loop {
        sequence = sequence.wrapping_add(1);
        let mut interleaved_samples = Vec::with_capacity(frame_samples * CAPTURE_CHANNELS as usize);
        for s in 0..frame_samples {
            for ch in 0..CAPTURE_CHANNELS as usize {
                interleaved_samples.push(((sequence as usize + s + ch) % 2048) as i32);
            }
        }

        tx.send(CaptureFrame {
            sequence,
            timestamp_micros: now_micros(),
            samples_per_channel: frame_samples,
            source: "mock",
            interleaved_samples,
        })?;
        thread::sleep(frame_interval);
    }
}

fn run_alsa_capture(
    tx: SyncSender<CaptureFrame>,
    device: &str,
    capture_rate_hz: u32,
    frame_samples: usize,
    sample_format: SampleFormat,
) -> anyhow::Result<()> {
    println!(
        "T1 capture mode: ALSA device '{device}' @ {capture_rate_hz}Hz format={:?}",
        sample_format
    );

    // Auto-rebind loop: keep retrying open/read after USB disconnects or ALSA device churn.
    let mut active_device = device.to_string();
    let mut rebinding_attempts: u64 = 0;

    loop {
        let session = run_alsa_capture_session(
            tx.clone(),
            &active_device,
            capture_rate_hz,
            frame_samples,
            sample_format,
        );

        match session {
            Ok(()) => {
                // Capture sessions are expected to run indefinitely; if one returns cleanly,
                // continue and attempt to rebind.
                eprintln!("ALSA capture session ended unexpectedly; attempting rebind");
            }
            Err(err) => {
                eprintln!(
                    "ALSA capture session error on '{}': {}. Attempting auto-rebind...",
                    active_device, err
                );
            }
        }

        rebinding_attempts = rebinding_attempts.saturating_add(1);
        thread::sleep(Duration::from_secs(2));

        if let Some(discovered) = discover_alsa_device_from_proc() {
            if discovered != active_device {
                eprintln!(
                    "ALSA rebind switched device '{}' -> '{}' (attempt #{})",
                    active_device, discovered, rebinding_attempts
                );
                active_device = discovered;
                continue;
            }
        }

        if rebinding_attempts % 5 == 0 {
            eprintln!(
                "ALSA rebind still targeting '{}' after {} attempts",
                active_device, rebinding_attempts
            );
        }
    }
}

fn run_alsa_capture_session(
    tx: SyncSender<CaptureFrame>,
    device: &str,
    capture_rate_hz: u32,
    frame_samples: usize,
    sample_format: SampleFormat,
) -> anyhow::Result<()> {

    let pcm = PCM::new(device, Direction::Capture, false)?;
    {
        let hwp = HwParams::any(&pcm)?;
        hwp.set_channels(CAPTURE_CHANNELS)?;
        hwp.set_rate(capture_rate_hz, ValueOr::Nearest)?;
        match sample_format {
            SampleFormat::S16Le => hwp.set_format(Format::s16())?,
            // Capture 24-bit sources in a 32-bit signed container for better headroom.
            SampleFormat::S24In32Le => hwp.set_format(Format::s32())?,
        }
        hwp.set_access(Access::RWInterleaved)?;
        hwp.set_period_size(frame_samples as i64, ValueOr::Nearest)?;
        pcm.hw_params(&hwp)?;
    }
    pcm.prepare()?;

    match sample_format {
        SampleFormat::S16Le => run_alsa_capture_s16(tx, pcm, frame_samples),
        SampleFormat::S24In32Le => run_alsa_capture_s32(tx, pcm, frame_samples),
    }
}

fn run_alsa_capture_s16(
    tx: SyncSender<CaptureFrame>,
    pcm: PCM,
    frame_samples: usize,
) -> anyhow::Result<()> {
    let io = pcm.io_i16()?;
    let mut interleaved_buf = vec![0_i16; frame_samples * CAPTURE_CHANNELS as usize];
    let mut sequence = 0_u64;

    loop {
        match io.readi(&mut interleaved_buf) {
            Ok(frames_read) => {
                sequence = sequence.wrapping_add(1);
                let samples_len = frames_read * CAPTURE_CHANNELS as usize;
                let interleaved_samples = interleaved_buf[..samples_len]
                    .iter()
                    .map(|&sample| sample as i32)
                    .collect::<Vec<_>>();
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

fn run_alsa_capture_s32(
    tx: SyncSender<CaptureFrame>,
    pcm: PCM,
    frame_samples: usize,
) -> anyhow::Result<()> {
    let io = pcm.io_i32()?;
    let mut interleaved_buf = vec![0_i32; frame_samples * CAPTURE_CHANNELS as usize];
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

fn split_group_interleaved(frame: &CaptureFrame, group: &StreamGroup) -> anyhow::Result<Vec<i32>> {
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

fn encode_pcm16le(interleaved_samples: &[i32], sample_format: SampleFormat) -> Vec<u8> {
    let mut payload = Vec::with_capacity(interleaved_samples.len() * 2);
    for &sample in interleaved_samples {
        let clipped = normalize_sample_to_pcm16(sample, sample_format);
        payload.extend_from_slice(&clipped.to_le_bytes());
    }
    payload
}

fn normalize_sample_to_pcm16(sample: i32, sample_format: SampleFormat) -> i16 {
    let normalized = match sample_format {
        SampleFormat::S16Le => sample,
        // 24-bit signal carried in 32-bit container -> map back to 16-bit payload/encoder input.
        SampleFormat::S24In32Le => sample >> 8,
    };
    normalized.clamp(i16::MIN as i32, i16::MAX as i32) as i16
}

fn encode_opus(
    encoder: &mut OpusEncoder,
    interleaved_samples: &[i32],
    sample_format: SampleFormat,
) -> anyhow::Result<Vec<u8>> {
    let pcm16 = interleaved_samples
        .iter()
        .map(|&sample| normalize_sample_to_pcm16(sample, sample_format))
        .collect::<Vec<_>>();

    let mut out = vec![0_u8; 4000];
    let encoded_len = encoder
        .encode(&pcm16, &mut out)
        .map_err(|err| anyhow::anyhow!("opus encode failed: {err}"))?;
    out.truncate(encoded_len);
    Ok(out)
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
    capture_rate_hz: u32,
    sample_format: SampleFormat,
    payload_codec: PayloadCodec,
    channel_activity: Arc<Mutex<Vec<ChannelActivity>>>,
    packet_integrity: Arc<Mutex<HashMap<u16, PacketIntegrityRow>>>,
    test_channel_count: usize,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut opus_encoders = std::collections::HashMap::<u16, OpusEncoder>::new();

        if matches!(payload_codec, PayloadCodec::Opus) {
            for group in &stream_groups {
                let channels = match group.channels.len() {
                    1 => Channels::Mono,
                    2 => Channels::Stereo,
                    n => {
                        eprintln!(
                            "stream {} skipped for opus: unsupported channel count {} (only mono/stereo)",
                            group.stream_id, n
                        );
                        continue;
                    }
                };

                match OpusEncoder::new(capture_rate_hz, channels, Application::Audio) {
                    Ok(enc) => {
                        opus_encoders.insert(group.stream_id, enc);
                    }
                    Err(err) => {
                        eprintln!(
                            "failed to create opus encoder for stream {}: {}",
                            group.stream_id, err
                        );
                    }
                }
            }
        }

        loop {
            match capture_rx.recv_timeout(Duration::from_millis(200)) {
                Ok(frame) => {
                    stats.capture_frames.fetch_add(1, Ordering::Relaxed);
                    update_channel_activity(&frame, test_channel_count, &channel_activity);

                    for group in &stream_groups {
                        let split = match split_group_interleaved(&frame, group) {
                            Ok(v) => v,
                            Err(err) => {
                                eprintln!("splitter error for stream {}: {err}", group.stream_id);
                                continue;
                            }
                        };

                        let encoded_payload = match payload_codec {
                            PayloadCodec::Pcm16 => encode_pcm16le(&split, sample_format),
                            PayloadCodec::Opus => {
                                let Some(encoder) = opus_encoders.get_mut(&group.stream_id) else {
                                    eprintln!(
                                        "stream {} skipped: no opus encoder available",
                                        group.stream_id
                                    );
                                    continue;
                                };

                                match encode_opus(encoder, &split, sample_format) {
                                    Ok(v) => v,
                                    Err(err) => {
                                        eprintln!(
                                            "opus encode error for stream {}: {}",
                                            group.stream_id, err
                                        );
                                        continue;
                                    }
                                }
                            }
                        };
                        let bytes = build_packet(&frame, group, &encoded_payload);
                        update_packet_integrity(
                            &packet_integrity,
                            group.stream_id,
                            frame.sequence,
                            frame.timestamp_micros,
                        );
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
        "runtime config: mode={:?} transport={:?} rate_hz={} sample_format={:?} payload_codec={:?} frame_samples={} dante_max_sources={} test_duration_secs={:?} test_channel_count={} groups={} udp_targets={} outbound_queue_depth={}",
        config.capture_mode,
        config.input_transport,
        config.capture_rate_hz,
        config.sample_format,
        config.payload_codec,
        config.frame_samples,
        config.dante_max_sources,
        config.test_duration_secs,
        config.test_channel_count,
        config.stream_groups.len(),
        config.udp_targets.len(),
        config.outbound_queue_depth
    );

    if matches!(config.capture_mode, CaptureMode::Alsa { .. })
        && matches!(config.input_transport, InputTransport::Dante)
    {
        let placeholder = DanteTransportConfig {
            sample_rate_hz: config.capture_rate_hz,
            max_sources: config.dante_max_sources,
        };
        build_dante_placeholder(placeholder)?;
        anyhow::bail!(
            "AUDIO_ENGINE_INPUT_TRANSPORT=dante is reserved for future implementation. Contract validated for Dante capabilities (rates include 96000 Hz, max 64 sources). Use AUDIO_ENGINE_INPUT_TRANSPORT=alsa_usb for current USB mixer capture."
        );
    }

    if !matches!(config.capture_mode, CaptureMode::Mock) && config.udp_targets.is_empty() {
        eprintln!(
            "startup warning: capture mode is not mock but AUDIO_ENGINE_UDP_TARGETS is empty; packets will be generated but not transmitted"
        );
    }

    let stats = Arc::new(PipelineStats::default());
    let channel_activity = Arc::new(Mutex::new(vec![
        ChannelActivity::default();
        config.test_channel_count
    ]));
    let packet_integrity = Arc::new(Mutex::new(HashMap::<u16, PacketIntegrityRow>::new()));

    let (capture_tx, capture_rx) = sync_channel::<CaptureFrame>(512);
    let (outbound_tx, outbound_rx) = sync_channel::<OutboundPacket>(config.outbound_queue_depth);

    let _capture_handle = spawn_capture_thread(
        capture_tx,
        config.capture_mode.clone(),
        config.capture_rate_hz,
        config.frame_samples,
        config.sample_format,
    );
    let _processor_handle = spawn_processing_thread(
        capture_rx,
        outbound_tx,
        config.stream_groups.clone(),
        stats.clone(),
        config.capture_rate_hz,
        config.sample_format,
        config.payload_codec,
        channel_activity.clone(),
        packet_integrity.clone(),
        config.test_channel_count,
    );
    let _sender_handle = spawn_udp_sender_thread(outbound_rx, config.udp_targets.clone(), stats.clone());

    let mut last_log = Instant::now();
    let start_time = Instant::now();

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

        if let Some(duration_secs) = config.test_duration_secs {
            if start_time.elapsed() >= Duration::from_secs(duration_secs) {
                println!("test window completed: {} seconds", duration_secs);
                print_channel_activity_summary(&channel_activity);
                print_packet_integrity_summary(&packet_integrity);
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_first_alsa_card_device_extracts_first_index() {
        let cards = " 0 [PCH            ]: HDA-Intel - HDA Intel PCH\n 1 [USB            ]: USB-Audio - USB Audio Device\n";
        let device = parse_first_alsa_card_device(cards).expect("should parse first card");
        assert_eq!(device, "plughw:0,0");
    }

    #[test]
    fn parse_first_alsa_card_device_prefers_wing_card_when_present() {
        let cards = " 0 [PCH            ]: HDA-Intel - HDA Intel PCH\n 1 [WING           ]: USB-Audio - Behringer WING\n";
        let device = parse_first_alsa_card_device(cards).expect("should parse wing card");
        assert_eq!(device, "plughw:1,0");
    }

    #[test]
    fn parse_first_alsa_card_device_prefers_behringer_label_when_present() {
        let cards = " 2 [USB            ]: USB-Audio - Generic USB Device\n 3 [XAIR           ]: USB-Audio - Behringer XR18\n";
        let device = parse_first_alsa_card_device(cards).expect("should parse behringer card");
        assert_eq!(device, "plughw:3,0");
    }

    #[test]
    fn parse_first_alsa_card_device_returns_none_when_empty() {
        let cards = "\n  [no cards]\n";
        assert!(parse_first_alsa_card_device(cards).is_none());
    }

    #[test]
    fn parse_channel_expr_accepts_ranges_and_lists() {
        let parsed = parse_channel_expr("0-2,4,6-7").expect("channel expression should parse");
        assert_eq!(parsed, vec![0, 1, 2, 4, 6, 7]);
    }

    #[test]
    fn parse_channel_expr_rejects_descending_range() {
        let err = parse_channel_expr("5-2").expect_err("descending range must fail");
        assert!(err.to_string().contains("start > end"));
    }

    #[test]
    fn capture_rate_from_env_accepts_44100_and_48000() {
        std::env::set_var("AUDIO_ENGINE_CAPTURE_RATE_HZ", "44100");
        assert_eq!(
            capture_rate_from_env(InputTransport::AlsaUsb).expect("44100 should be valid"),
            44_100
        );

        std::env::set_var("AUDIO_ENGINE_CAPTURE_RATE_HZ", "48000");
        assert_eq!(
            capture_rate_from_env(InputTransport::AlsaUsb).expect("48000 should be valid"),
            48_000
        );

        std::env::remove_var("AUDIO_ENGINE_CAPTURE_RATE_HZ");
    }

    #[test]
    fn capture_rate_from_env_rejects_other_values() {
        std::env::set_var("AUDIO_ENGINE_CAPTURE_RATE_HZ", "32000");
        let err = capture_rate_from_env(InputTransport::AlsaUsb).expect_err("32000 must be rejected");
        assert!(err.to_string().contains("Supported values: 44100, 48000"));
        std::env::remove_var("AUDIO_ENGINE_CAPTURE_RATE_HZ");
    }

    #[test]
    fn capture_rate_from_env_accepts_96000_for_dante() {
        std::env::set_var("AUDIO_ENGINE_CAPTURE_RATE_HZ", "96000");
        assert_eq!(
            capture_rate_from_env(InputTransport::Dante).expect("96000 should be valid for dante"),
            96_000
        );
        std::env::remove_var("AUDIO_ENGINE_CAPTURE_RATE_HZ");
    }

    #[test]
    fn input_transport_from_env_accepts_alsa_usb_and_dante() {
        std::env::set_var("AUDIO_ENGINE_INPUT_TRANSPORT", "alsa_usb");
        let alsa = input_transport_from_env().expect("alsa_usb should parse");
        assert!(matches!(alsa, InputTransport::AlsaUsb));

        std::env::set_var("AUDIO_ENGINE_INPUT_TRANSPORT", "dante");
        let dante = input_transport_from_env().expect("dante should parse");
        assert!(matches!(dante, InputTransport::Dante));

        std::env::remove_var("AUDIO_ENGINE_INPUT_TRANSPORT");
    }

    #[test]
    fn input_transport_from_env_rejects_unknown_values() {
        std::env::set_var("AUDIO_ENGINE_INPUT_TRANSPORT", "aes67");
        let err = input_transport_from_env().expect_err("unknown transport must fail");
        assert!(err
            .to_string()
            .contains("Supported values: alsa_usb, dante"));
        std::env::remove_var("AUDIO_ENGINE_INPUT_TRANSPORT");
    }

    #[test]
    fn capture_sample_format_from_env_accepts_supported_values() {
        std::env::set_var("AUDIO_ENGINE_SAMPLE_FORMAT", "s16_le");
        assert!(matches!(
            capture_sample_format_from_env().expect("s16_le should parse"),
            SampleFormat::S16Le
        ));

        std::env::set_var("AUDIO_ENGINE_SAMPLE_FORMAT", "s24_in_32_le");
        assert!(matches!(
            capture_sample_format_from_env().expect("s24_in_32_le should parse"),
            SampleFormat::S24In32Le
        ));

        std::env::remove_var("AUDIO_ENGINE_SAMPLE_FORMAT");
    }

    #[test]
    fn capture_sample_format_from_env_rejects_unknown_values() {
        std::env::set_var("AUDIO_ENGINE_SAMPLE_FORMAT", "s24_3le");
        let err = capture_sample_format_from_env().expect_err("unknown sample format must fail");
        assert!(err
            .to_string()
            .contains("Supported values: s16_le, s24_in_32_le"));
        std::env::remove_var("AUDIO_ENGINE_SAMPLE_FORMAT");
    }

    #[test]
    fn payload_codec_from_env_accepts_supported_values() {
        std::env::set_var("AUDIO_ENGINE_PAYLOAD_CODEC", "pcm16");
        assert!(matches!(
            payload_codec_from_env().expect("pcm16 should parse"),
            PayloadCodec::Pcm16
        ));

        std::env::set_var("AUDIO_ENGINE_PAYLOAD_CODEC", "opus");
        assert!(matches!(
            payload_codec_from_env().expect("opus should parse"),
            PayloadCodec::Opus
        ));

        std::env::remove_var("AUDIO_ENGINE_PAYLOAD_CODEC");
    }

    #[test]
    fn payload_codec_from_env_rejects_unknown_values() {
        std::env::set_var("AUDIO_ENGINE_PAYLOAD_CODEC", "flac");
        let err = payload_codec_from_env().expect_err("unknown payload codec must fail");
        assert!(err
            .to_string()
            .contains("Supported values: pcm16, opus"));
        std::env::remove_var("AUDIO_ENGINE_PAYLOAD_CODEC");
    }

    #[test]
    fn dante_max_sources_from_env_rejects_values_over_limit() {
        std::env::set_var("AUDIO_ENGINE_DANTE_MAX_SOURCES", "65");
        let err = dante_max_sources_from_env().expect_err("65 should be out of range");
        assert!(err.to_string().contains("Allowed: 1..=64"));
        std::env::remove_var("AUDIO_ENGINE_DANTE_MAX_SOURCES");
    }

    #[test]
    fn build_packet_sets_header_and_payload_length() {
        let frame = CaptureFrame {
            sequence: 7,
            timestamp_micros: 123_456,
            samples_per_channel: 20,
            source: "test",
            interleaved_samples: Vec::new(),
        };
        let group = StreamGroup {
            stream_id: 100,
            channels: vec![0, 1],
        };
        let payload = vec![1_u8, 2, 3, 4];

        let packet = build_packet(&frame, &group, &payload);

        assert_eq!(&packet[0..4], b"BDRS");
        assert_eq!(u16::from_be_bytes([packet[8], packet[9]]), 100);
        assert_eq!(packet[10], 2);
        assert_eq!(u32::from_be_bytes([packet[29], packet[30], packet[31], packet[32]]), 4);
        assert_eq!(&packet[33..], payload.as_slice());
    }

    #[test]
    fn build_packet_preserves_sequence_and_timestamp_monotonicity() {
        let group = StreamGroup {
            stream_id: 101,
            channels: vec![2, 3],
        };
        let payload = vec![0_u8; 8];

        let frame_a = CaptureFrame {
            sequence: 10,
            timestamp_micros: 1_000,
            samples_per_channel: 20,
            source: "test",
            interleaved_samples: Vec::new(),
        };
        let frame_b = CaptureFrame {
            sequence: 11,
            timestamp_micros: 2_000,
            samples_per_channel: 20,
            source: "test",
            interleaved_samples: Vec::new(),
        };

        let packet_a = build_packet(&frame_a, &group, &payload);
        let packet_b = build_packet(&frame_b, &group, &payload);

        let seq_a = u64::from_be_bytes([
            packet_a[13],
            packet_a[14],
            packet_a[15],
            packet_a[16],
            packet_a[17],
            packet_a[18],
            packet_a[19],
            packet_a[20],
        ]);
        let seq_b = u64::from_be_bytes([
            packet_b[13],
            packet_b[14],
            packet_b[15],
            packet_b[16],
            packet_b[17],
            packet_b[18],
            packet_b[19],
            packet_b[20],
        ]);

        let ts_a = u64::from_be_bytes([
            packet_a[21],
            packet_a[22],
            packet_a[23],
            packet_a[24],
            packet_a[25],
            packet_a[26],
            packet_a[27],
            packet_a[28],
        ]);
        let ts_b = u64::from_be_bytes([
            packet_b[21],
            packet_b[22],
            packet_b[23],
            packet_b[24],
            packet_b[25],
            packet_b[26],
            packet_b[27],
            packet_b[28],
        ]);

        assert!(seq_b > seq_a);
        assert!(ts_b > ts_a);
    }

    #[test]
    fn packet_integrity_tracker_counts_sequence_gaps() {
        let integrity = Arc::new(Mutex::new(HashMap::<u16, PacketIntegrityRow>::new()));

        update_packet_integrity(&integrity, 100, 1, 1_000);
        update_packet_integrity(&integrity, 100, 3, 2_000);

        let guard = integrity.lock().expect("integrity lock should work");
        let row = guard.get(&100).expect("row should exist");
        assert_eq!(row.packet_count, 2);
        assert_eq!(row.sequence_gaps, 1);
        assert_eq!(row.duplicate_sequences, 0);
        assert_eq!(row.timestamp_regressions, 0);
    }

    #[test]
    fn packet_integrity_tracker_counts_timestamp_regressions() {
        let integrity = Arc::new(Mutex::new(HashMap::<u16, PacketIntegrityRow>::new()));

        update_packet_integrity(&integrity, 101, 10, 2_000);
        update_packet_integrity(&integrity, 101, 11, 1_500);

        let guard = integrity.lock().expect("integrity lock should work");
        let row = guard.get(&101).expect("row should exist");
        assert_eq!(row.packet_count, 2);
        assert_eq!(row.sequence_gaps, 0);
        assert_eq!(row.timestamp_regressions, 1);
    }
}
