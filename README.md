# BDRS

Broadcast Distribution RTA System

Current baseline release: `v0.2.0`

This repository contains the early implementation baseline for a modular audio distribution system:

- `audio-engine` (Rust): 48-channel capture and UDP pipeline scaffold
- `control-plane` (Node.js): basic HTTP service scaffold
- `redis` and `nats` infrastructure via Docker Compose
- Proxmox LXC config and helper script artifacts

## Current baseline status

- Control plane scaffold is runnable in Docker Compose.
- Audio engine builds and runs in Linux environments with ALSA development headers.
- Milestone 2 pipeline scaffold is implemented (capture, split, packetize, UDP send, queue/backpressure stats).

## Repository layout

```text
audio-engine/      Rust audio capture + packet pipeline
control-plane/     Node.js control plane scaffold
Implementation/    implementation package + milestone checklist
ProxMox/           LXC config and helper bootstrap artifacts
docker-compose.yml local baseline stack (control-plane, redis, nats)
```

## Prerequisites

For local baseline (Compose only):

- Docker Desktop with Compose support

For building/running `audio-engine` directly:

- Linux environment (LXC/VM recommended)
- Rust stable toolchain
- ALSA development package (`libasound2-dev` on Ubuntu/Debian)

## Quickstart (baseline)

1. From repo root, start the baseline services:

```bash
docker compose up -d
```

2. Verify service health:

```bash
curl http://localhost:8080/health
```

Expected response:

```json
{"status":"ok","service":"control-plane"}
```

3. Optional checks:

```bash
curl http://localhost:8080/
docker compose ps
```

4. Stop the stack when done:

```bash
docker compose down
```

## Running audio-engine locally

Copy and adjust environment variables:

```bash
cp audio-engine/.env.example audio-engine/.env
```

Current runtime variables used by the Rust pipeline are:

- `AUDIO_ENGINE_CAPTURE_MODE` (`mock` or `alsa`)
- `AUDIO_ENGINE_INPUT_TRANSPORT` (`alsa_usb` currently, `dante` reserved for future)
- `AUDIO_ENGINE_ALSA_DEVICE` (when ALSA mode is used)
- `AUDIO_ENGINE_CAPTURE_RATE_HZ` (`44100` or `48000` for `alsa_usb`; `96000` also allowed for planned `dante`)
- `AUDIO_ENGINE_SAMPLE_FORMAT` (`s24_in_32_le` default for WING-friendly capture, or `s16_le` compatibility mode)
- `AUDIO_ENGINE_PAYLOAD_CODEC` (`pcm16` default packet payloads, or `opus` for 20 ms Opus encoding at 48000 Hz)
- `AUDIO_ENGINE_DANTE_MAX_SOURCES` (`1..64`, future `dante` contract)
- `AUDIO_ENGINE_STREAM_GROUPS` (example: `100:0-1;101:2-3`)
- `AUDIO_ENGINE_UDP_TARGETS` (comma-separated `host:port` list)
- `AUDIO_ENGINE_OUTBOUND_QUEUE_DEPTH` (positive integer)

For WING deployments, set `AUDIO_ENGINE_CAPTURE_RATE_HZ` to match the current console clock rate.
Use `AUDIO_ENGINE_SAMPLE_FORMAT=s24_in_32_le` to preserve 24-bit source resolution in a 32-bit container through capture/analysis.
Set `AUDIO_ENGINE_INPUT_TRANSPORT=alsa_usb` for USB mixers today; `dante` is exposed now as a configuration contract for future implementation.
The Dante placeholder contract tracks support planning for up to `96000` Hz and up to `64` sources.
The ALSA capture thread now includes hotplug auto-rebind behavior: on open/read failures it retries and re-discovers available ALSA cards to recover after USB disconnect/reconnect events.
Set `AUDIO_ENGINE_PAYLOAD_CODEC=opus` if you want the processing stage to emit 20 ms Opus-encoded payloads instead of PCM16 packets; the code currently enforces `48000` Hz for that mode and supports mono/stereo stream groups only.

## Control-plane audio input settings API

The control-plane now persists and serves audio input settings with WING-oriented defaults while allowing post-setup updates for other mixers.

- `GET /settings/audio-input`: fetch current settings, capabilities, and derived audio-engine env map
- `PUT /settings/audio-input`: update one or more settings with validation
- `POST /settings/audio-input/reset`: reset settings to baseline defaults (`control-plane/audio-input.settings.default.json`)

Default persisted file:

- `control-plane/audio-input.settings.json`

Example read:

```bash
curl http://localhost:8080/settings/audio-input
```

Example update (switch to 48 kHz + 16-bit compatibility):

```bash
curl -X PUT http://localhost:8080/settings/audio-input \
	-H "Content-Type: application/json" \
	-d '{"captureRateHz":48000,"sampleFormat":"s16_le","mixerProfile":"generic-usb"}'
```

Example run:

```bash
cd audio-engine
cargo run
```

### Source visibility test (bounded)

To run a 5-minute source visibility test (for example, 16 USB sources at 44.1 kHz):

```bash
cd audio-engine
env \
	AUDIO_ENGINE_CAPTURE_MODE=alsa \
	AUDIO_ENGINE_INPUT_TRANSPORT=alsa_usb \
	AUDIO_ENGINE_CAPTURE_RATE_HZ=44100 \
	AUDIO_ENGINE_ALSA_DEVICE=plughw:0,0 \
	AUDIO_ENGINE_TEST_DURATION_SECS=300 \
	AUDIO_ENGINE_TEST_CHANNEL_COUNT=16 \
	cargo run
```

At the end of the test window, the process exits and prints a `Source Activity Summary` block with per-channel status (`ACTIVE` or `SILENT`), non-zero percentage, and peak sample value.
It also prints a `Packet Integrity Summary` block that reports per-stream packet counts, sequence gaps, duplicate sequences, and timestamp regressions.

For Milestone 2 acceptance at the current 30-minute target, use:

```bash
cd audio-engine
bash scripts/run_milestone2_acceptance.sh
```

Override duration if needed:

```bash
cd audio-engine
bash scripts/run_milestone2_acceptance.sh --duration-secs 600
```

If ALSA headers are missing, install:

```bash
sudo apt-get update
sudo apt-get install -y libasound2-dev
```

## Environment templates

- `audio-engine/.env.example`
- `control-plane/.env.example`
- `control-plane/audio-input.settings.default.json`

## Proxmox bootstrap and repo-driven defaults

`ProxMox/helper/bdrs.sh` now supports pulling startup defaults directly from the Git repository when LXCs are created and started.

During the wizard, set:

- `repoUrl` (default: `https://github.com/foxhoundv/BDRS.git`)
- `repoRef` (default: `v0.2.0`)
- `syncDefaultsFromRepo` (default: `true`)

When enabled, each started LXC clones/pulls the configured repo ref into `/opt/bdrs/repo`, and seeds default settings files if missing:

- `audio-engine/.env` from `audio-engine/.env.example`
- `control-plane/.env` from `control-plane/.env.example`
- `control-plane/audio-input.settings.json` from `control-plane/audio-input.settings.default.json`

The same sync step also mirrors the checked-out repository into `/opt/bdrs/deploy/current` and updates `/opt/bdrs/current` to point at that live deployment tree, so a fresh bootstrap brings in the full latest repo contents, not just default config files.

### Sync existing LXCs without rebuild

You can refresh already-running LXCs without deleting/recreating them:

```bash
./ProxMox/helper/bdrs.sh --sync-only
```

Optional overrides:

```bash
./ProxMox/helper/bdrs.sh --sync-only \
	--repo-url https://github.com/foxhoundv/BDRS.git \
	--repo-ref v0.2.0 \
	--control-vmid 201 \
	--audio-vmid 200 \
	--recording-vmid 202
```

`--sync-only` performs repository pull + deployment mirror + default-config seeding for the target LXCs, and skips interactive provisioning prompts.
Before syncing, it checks the latest upstream `v*` release tag and prompts whether to keep the selected/current `--repo-ref` or move to the newer release.

User setting overrides are preserved across sync runs:

- Override snapshots are stored under `/opt/bdrs/state/user-overrides`.
- A settings path manifest at `/opt/bdrs/state/settings-manifest.tsv` tracks where key settings live.
- During sync, the script preserves current user-edited settings, updates files, then reapplies overrides.

This prevents users from redoing settings after updates and helps carry settings forward when tracked config paths move.

## Proxmox rule

Never install project software directly on the Proxmox host. Build and runtime dependencies belong in project LXCs/VMs only.

Persistent WING USB mapping reference rule is available at `ProxMox/99-wing.rules` (USB ID `1397:050b`).

## Branch and release strategy

- Branch naming: `feature/<scope>`, `fix/<scope>`, `ops/<scope>`
- Milestone stabilization branch example: `release/m2-mvp`
- Current release tag: `v0.2.0`
- Historical examples: `v0.1.0-m0`, `v0.2.0-m1`

## Next priorities

- Implement ALSA device discovery + persistent mapping for WING
- Add hotplug/rebind handling
- Add Opus encoding stage
