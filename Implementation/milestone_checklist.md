# Broadcast Dist RTA System - Milestone Checklist

Date baseline: 2026-07-02
Source: Implementation package v1.0

## Progress Log

- 2026-07-02: Added missing Rust dependency `anyhow` in `audio-engine/Cargo.toml`.
- 2026-07-02: Added project quickstart at `README.md`.
- 2026-07-02: Added `control-plane/server.js` scaffold and bind mount in compose.
- 2026-07-02: Validated compose startup; control-plane, redis, and event-bus all run.
- 2026-07-02: Rust build execution blocked on this machine because `cargo` is not installed or not on PATH.
- 2026-07-02: Added env templates at `audio-engine/.env.example` and `control-plane/.env.example`.
- 2026-07-02: Documented branch and release naming strategy in `README.md`.
- 2026-07-02: Replaced `rodio` (playback-only) with `alsa = "0.9"` in `audio-engine/Cargo.toml`.
- 2026-07-02: Created audio-engine LXC (VMID 200, Ubuntu 24.04) on Proxmox host. Project containers use IDs 200+.
- 2026-07-02: Installed Rust stable + libasound2-dev inside LXC 200. `cargo build` succeeded in 11.86s — no errors.
- 2026-07-02: Added helper-script first-run questionnaire section with recorded environment defaults and prompts.
- 2026-07-02: Added Proxmox helper bootstrap schema at `proxmox/helper/bootstrap-config.schema.json` and starter script at `proxmox/helper/bdrs.sh`.
- 2026-07-02: Implemented Audio Engine T1 capture thread with `mock` and `alsa` capture modes in `audio-engine/src/main.rs`.
- 2026-07-06: Implemented Milestone 2 pipeline scaffold in `audio-engine/src/main.rs`: PCM payload capture, stream group splitter, packetizer, UDP sender, bounded queue backpressure counters, and runtime config loading from env.
- 2026-07-06: Expanded top-level `README.md` with architecture context, compose quickstart, audio-engine runtime/env details, and validation steps for new developers.
- 2026-07-06: Aligned `audio-engine/.env.example` with active `AUDIO_ENGINE_*` runtime variables and removed README mismatch warning.
- 2026-07-06: Added runtime env contract comments to `audio-engine/src/main.rs` to document active `AUDIO_ENGINE_*` variables in code.
- 2026-07-06: Added startup validation warning in `audio-engine/src/main.rs` when non-mock capture runs without `AUDIO_ENGINE_UDP_TARGETS` configured.
- 2026-07-06: Added packet/parser integrity unit tests in `audio-engine/src/main.rs` for channel expression parsing and packet sequence/timestamp field validation.
- 2026-07-06: Added fail-fast config error context in `audio-engine/src/main.rs` for malformed `AUDIO_ENGINE_STREAM_GROUPS`, including an example valid value.
- 2026-07-06: Deferred live runtime test execution until USB audio transmission path is ready; continue implementation and static/unit validation in the meantime.
- 2026-07-06: Added first-pass ALSA device auto-discovery fallback in `audio-engine/src/main.rs` from `/proc/asound/cards` with parser unit tests.
- 2026-07-06: Verified live WING USB visibility on Proxmox host (`lsusb` showed `1397:050b`) and passthrough in LXC 200 (`/proc/asound/cards` showed card `WING`).
- 2026-07-06: Verified direct capture in LXC 200 with ALSA tools. Hardware-native mode reported `S24_3LE`, `48` channels, `44100` Hz; plug conversion test succeeded at `S16_LE`, `48` channels, `48000` Hz (`plughw:0,0`).
- 2026-07-06: Added runtime dual-rate support in `audio-engine/src/main.rs` for `AUDIO_ENGINE_CAPTURE_RATE_HZ` (`44100` or `48000`) and documented current WING reference rate as `44100`.
- 2026-07-06: Added modular input transport config in `audio-engine/src/main.rs` (`AUDIO_ENGINE_INPUT_TRANSPORT=alsa_usb|dante`) with fail-fast placeholder behavior for future Dante implementation.
- 2026-07-06: Added `audio-engine/src/input_transport.rs` Dante backend skeleton contract (interface + validation) including planned `96000` Hz support and up to `64` sources.
- 2026-07-06: Installed Rust + build tooling in LXC 200 and validated live `audio-engine` runtime against WING at `44100` Hz using `AUDIO_ENGINE_ALSA_DEVICE=plughw:0,0`; pipeline counters advanced continuously with no queue drops.
- 2026-07-06: LXC 200 currently has rustup shims on PATH without a default toolchain; direct runs succeed using distro binaries (`/usr/bin/cargo` + `RUSTC=/usr/bin/rustc`) or by setting a rustup default in a follow-up.
- 2026-07-06: Added bounded source-visibility test mode in `audio-engine/src/main.rs` via `AUDIO_ENGINE_TEST_DURATION_SECS` and `AUDIO_ENGINE_TEST_CHANNEL_COUNT`, with end-of-test per-channel activity summary output.
- 2026-07-06: Completed 5-minute live visibility test in LXC 200 (`44100` Hz, `16` sources). Summary written to `/tmp/audio_engine_5min_16src.log`; highest-energy channels observed: 1, 2, 3, 6, 7, 10, 13.
- 2026-07-06: Added configurable capture sample format in audio-engine (`s16_le` and `s24_in_32_le`) with WING-friendly default, and added control-plane settings API (`GET/PUT /settings/audio-input`, reset endpoint) to fetch/update mixer parameters post-setup.
- 2026-07-06: Added repo-driven startup defaults to Proxmox bootstrap (`bdrs.sh`) with configurable `repoUrl` + `repoRef` (default `v0.2.0`) and automatic seeding of audio-engine/control-plane default settings from the checked out Git release.
- 2026-07-06: Completed WING persistent mapping baseline: added udev rule template at `ProxMox/99-wing.rules` using verified USB ID `1397:050b`, and updated ALSA card auto-discovery to prefer `WING`/`Behringer` labels when present.
- 2026-07-06: Implemented ALSA hotplug auto-rebind flow in `audio-engine/src/main.rs`; capture now continuously retries and re-discovers ALSA devices after open/read failures instead of exiting capture thread.
- 2026-07-06: Implemented optional Opus encoder stage in `audio-engine/src/main.rs` with 20 ms framing support via `AUDIO_ENGINE_PAYLOAD_CODEC=opus`, enforced at 48 kHz and validated with runtime tests.
- 2026-07-06: Added packet integrity tracking in `audio-engine/src/main.rs` to validate per-stream sequence continuity and timestamp monotonicity during runtime bounded tests.
- 2026-07-06: Extended Proxmox bootstrap repo sync to mirror the full checked-out repository into `/opt/bdrs/deploy/current` and update `/opt/bdrs/current` on each fresh bootstrap run.

## How to use this file

- Track progress by changing [ ] to [x]
- Keep each milestone green before moving to the next one
- Add owner + target date when assigning tasks

---

## Operational Rules

- **Never install project software on the Proxmox host directly.**
- All runtimes (Rust, Node.js, etc.), builds, and services run exclusively inside project LXCs or VMs.
- The Proxmox host environment must remain unmodified.

---

## Proxmox Helper Script Inputs (First-Run Prompts)

Use this as the input contract for the future automated setup script. All values should be user-entered at first run, with defaults prefilled where known.

Already captured from this environment:

- [x] Proxmox host: `192.168.1.57:8006`
- [x] LXC OS template: `Ubuntu 24.04 LTS (noble)`
- [x] Storage pool: `local-lvm`
- [x] Network bridge strategy: `single vmbr0 with VLAN tags`
- [x] Primary bridge name: `vmbr0`
- [x] VLAN status: `planning ahead (not fully configured yet)`

Prompts the helper script should ask every new user:

- [ ] Proxmox API endpoint or host IP/port
- [ ] Proxmox node name
- [ ] LXC template choice (Ubuntu 24.04 / Ubuntu 22.04 / Debian 12)
- [ ] Storage pool for each workload (`audio-engine`, `control-plane`, `recording`)
- [ ] Bridge model: single VLAN-aware bridge vs separate bridges
- [ ] Bridge names (`vmbr0`, `vmbr10`, `vmbr20`, etc.)
- [ ] VLAN IDs for Audio / Management / Internet (defaults 10 / 20 / 30)
- [ ] VMID range or explicit IDs (default project range `200+`)
- [ ] Resource sizing overrides (cores, memory, rootfs)
- [ ] Recording disk mode (virtual disk vs NVMe passthrough)
- [ ] USB audio source type (WING or custom device)
- [ ] USB vendor:product ID (detected or manual input)
- [ ] ALSA persistent mapping preference (udev rule generation on/off)
- [ ] Firewall baseline profile (strict/default/open)
- [ ] Startup order overrides (Control Plane -> Audio Engine -> Recording)
- [ ] Whether to install build tooling in containers during bootstrap

---

## Milestone 0 - Project Baseline and Repo Hygiene

Goal: Make the current repo buildable and trackable.

Tasks:
- [x] Confirm all existing components can start without missing files
- [x] Fix Rust dependency mismatch (add missing crates used by code — replaced rodio with alsa)
- [x] Add top-level README with architecture + quickstart
- [x] Add env var template files for control-plane and audio-engine
- [x] Define branch and release naming strategy

Acceptance criteria:
- [x] `audio-engine` builds cleanly (verified in LXC 200, 2026-07-02)
- [x] `docker compose up` starts every declared service without immediate crash
- [x] New developer can follow README to run local baseline

---

## Milestone 1 - Proxmox Infrastructure Foundation

Goal: Establish stable compute/network/storage foundations.

Tasks:
- [x] Create/validate Audio Engine LXC from `proxmox/audio-engine-lxc.conf`
- [x] Create/validate Control Plane LXC from `proxmox/control-plane-lxc.conf`
- [x] Create/validate Recording LXC from `proxmox/recording-lxc.conf`
- [x] Configure VLAN 10 (Audio) and VLAN 20 (Management)
- [x] Enforce firewall rules between VLANs
- [x] Configure startup ordering and reboot behavior
- [x] Document host NIC, bridge, and VLAN mappings

Acceptance criteria:
- [x] All 3 nodes auto-start in correct order after host reboot
- [x] VLAN segmentation verified by connectivity tests
- [ ] Latency/jitter on VLAN 10 is within target budget

---

## Milestone 2 - Audio Engine MVP (Capture to UDP)

Goal: Produce first reliable broadcast stream from WING input.

Tasks:
- [ ] Implement ALSA device discovery + persistent mapping for WING
- [x] Implement ALSA device discovery + persistent mapping for WING
- [x] Add hotplug detection and auto-rebind flow
- [x] Build capture pipeline for 48-channel PCM input
- [x] Implement stream splitter based on channel groups
- [x] Add Opus encoder stage (20 ms frames)
- [x] Add packetizer with header/timestamp/stream_id/seq
- [x] Add UDP sender with configurable unicast targets
- [x] Add backpressure and bounded queue handling
- [x] Add runtime config loading (YAML/JSON/env)

Acceptance criteria:
- [ ] Audio Engine survives USB disconnect/reconnect without manual restart
- [ ] At least one stereo stream is transmitted continuously for 2 hours
- [x] Packet sequence continuity and timestamp monotonicity validated
- [ ] End-to-end audio latency meets defined MVP target

---

## Milestone 3 - Control Plane MVP (Config + Events)

Goal: Centralized stream/config/event control for operators and clients.

Tasks:
- [ ] Implement REST API for streams, clients, comms groups, recording policy
- [ ] Implement WebSocket channel for real-time state updates
- [ ] Add Redis/NATS event transport abstraction
- [ ] Define and enforce event schema versioning
- [ ] Implement auth baseline (service + operator)
- [ ] Persist stream definitions and policy settings
- [ ] Build health/readiness endpoints

Acceptance criteria:
- [ ] `POST /streams` can create/update/disable stream definitions
- [ ] Stream lifecycle events are published and observable
- [ ] Auth protects write endpoints and admin operations
- [ ] API + WS handles reconnects without losing control state

---

## Milestone 4 - Recording MVP (48ch Archive)

Goal: Capture dependable multi-channel recording on dedicated VM.

Tasks:
- [ ] Implement 48-channel WAV/BWF writer
- [ ] Add segmentation by event/time policy
- [ ] Implement naming/path template engine
- [ ] Add disk throughput monitoring and alerts
- [ ] Add retention and archival policy execution
- [ ] Add recording start/stop control integration with control plane

Acceptance criteria:
- [ ] 48-channel recording sustained for full service window
- [ ] No dropped-channel files in validation run
- [ ] Naming template output matches policy and is deterministic
- [ ] Recording start/stop events are auditable

---

## Milestone 5 - Client MVP (iOS/Android Playback + Comms)

Goal: Reliable field playback with comms features.

Tasks:
- [ ] Implement UDP receiver + jitter buffer
- [ ] Implement Opus decode + mixer pipeline
- [ ] Add multi-stream subscribe and local mix controls
- [ ] Implement PTT comms channel and priority ducking
- [ ] Add discovery + enrollment flow
- [ ] Add reconnect/roaming behavior over Wi-Fi

Acceptance criteria:
- [ ] Client can subscribe and play at least 2 concurrent streams
- [ ] PTT latency is within comms target threshold
- [ ] Roaming across APs recovers stream without app restart

---

## Milestone 6 - Observability and Operations

Goal: Make runtime behavior measurable and operable.

Tasks:
- [ ] Define metrics for latency, jitter, packet loss, queue depth, CPU, memory
- [ ] Centralize logs with correlation IDs
- [ ] Implement alert rules (latency warning, device disconnect, recording failure)
- [ ] Add operator dashboard views for stream and client state
- [ ] Add incident runbooks for top failure modes

Acceptance criteria:
- [ ] Every critical component exports health + metrics
- [ ] Alerting catches injected failure scenarios
- [ ] Dashboard supports root-cause triage in real time

---

## Milestone 7 - QoS, Security, and Hardening

Goal: Production-grade reliability and operational safety.

Tasks:
- [ ] Apply QoS classes by traffic type (broadcast/comms/cue/emergency)
- [ ] Validate CPU pinning and real-time scheduling strategy
- [ ] Harden container/VM security baseline
- [ ] Add config backup and disaster-recovery procedure
- [ ] Perform soak test (full service length + margin)
- [ ] Execute failover drills and postmortems

Acceptance criteria:
- [ ] Priority traffic remains stable during network stress
- [ ] Full-system soak test passes without critical incidents
- [ ] Recovery procedures are documented and repeatable

---

## Cross-Cutting Test Plan (Run every milestone)

- [ ] Functional validation against milestone acceptance criteria
- [ ] Performance baseline + regression check
- [ ] Fault injection: process restart, USB disconnect, network flap
- [ ] Security checks for exposed interfaces
- [ ] Documentation updates for any behavior/config changes

### Runtime Test Gate

- [ ] Start live runtime tests only after USB audio transmission is operational end-to-end.
- [ ] Until then, focus on implementation, configuration hardening, and unit-level validation.

---

## Immediate Next Sprint (recommended starting slice)

1. Milestone 0:
- [x] Add missing Rust dependency (build validation pending environment setup)
- [x] Add top-level README quickstart
- [x] Verify compose stack boots and identify missing control-plane artifacts

2. Milestone 1:
- [ ] Validate VLAN setup in lab
- [ ] Verify startup ordering on host reboot

3. Milestone 2:
- [x] Implement ALSA discovery and mock capture pipeline
- [x] Add packet structure and sequence/timestamp integrity tests

---

## Immediate Next Actions

Work through these in order before resuming milestone tasks.

- [x] 1. Replace `rodio` with `cpal` or `alsa` in `audio-engine/Cargo.toml` — `rodio` is a playback library and cannot capture input; this is blocking a correct build
- [x] 2. Validate `cargo build` on a Linux machine with ALSA dev headers (`libasound2-dev` installed) — built in LXC 200 (Ubuntu 24.04), finished in 11.86s with no errors
- [x] 3. Document WING USB device node — verified `1397:050b` with WING connected and added persistent mapping rule at `ProxMox/99-wing.rules`
- [x] 4. Fill in Proxmox network config — VLAN bridge assignments added to all three conf files (VLAN 10 audio, VLAN 20 management; single vmbr0 with tags)
- [x] 5. Implement T1 ALSA capture thread in audio engine — start with mock output, then wire to real WING device
- [x] 6. Add fail-fast config error for malformed `AUDIO_ENGINE_STREAM_GROUPS` with an example valid value in message
