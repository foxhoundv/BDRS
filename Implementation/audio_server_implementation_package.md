# Broadcast-grade Distributed RTA Server — Implementation Package

## Version 1.0

This document defines the full implementation blueprint for a modular WiFi-based broadcast, communications, and 48-channel recording system built on Proxmox.

---

# 1. SYSTEM OVERVIEW

This system provides:

- 48-channel USB audio capture (Behringer WING)
- Multi-stream Opus broadcast over WiFi
- Staff communication (PTT / intercom plane)
- 48-channel WAV recording system
- Mobile iOS + Android client apps
- Event-driven control plane
- Real-time observability dashboard

---

# 2. HIGH-LEVEL ARCHITECTURE

```
[Behringer WING USB 48ch]
            ↓
   [Audio Engine LXC]
            ↓
   ├── Broadcast Streams (UDP/Opus)
   ├── Comms Plane (PTT)
   └── Event Bus (internal)

            ↓
   [Control Plane LXC]
            ↓
   API + Config + Auth + Events

            ↓
   [Recording VM]
            ↓
   WAV/BWF 48-channel archive storage

            ↓
   [Mobile Clients iOS / Android]
```

---

# 3. PROXMOX DEPLOYMENT LAYOUT

## Containers / VMs

### Audio Engine LXC

- Privileged
- USB passthrough (WING)
- CPU pinned cores
- No disk dependency

### Control Plane LXC

- REST + WebSocket API
- Event bus (Redis/NATS)
- Stream configuration

### Recording VM

- NVMe passthrough recommended
- High sustained write load
- 48-channel WAV capture

### Client Services LXC

- Device discovery
- Subscription management

---

# 4. NETWORK DESIGN

## VLAN Architecture

### VLAN 10 — Audio Network

- UDP streams
- Comms plane
- mDNS discovery

### VLAN 20 — Management

- Proxmox UI
- SSH
- Admin dashboard

---

# 5. AUDIO ENGINE SPECIFICATION

## Responsibilities

- Capture 48-channel USB PCM
- Split into stream groups
- Encode Opus (20ms frames)
- Send UDP packets

## Constraints

- No disk I/O
- No UI
- No AI processing

## Thread Model

- Thread 1: ALSA capture (real-time)
- Thread 2: stream splitter
- Thread 3: Opus encoder
- Thread 4: UDP sender

---

# 6. STREAM MODEL

## Example Stream Mapping

- Stream 1 → Channels 1-2 (Main)
- Stream 2 → Channels 3-4 (Spanish)
- Stream 3 → Channels 5-8 (Band)
- Stream 4 → Channels 9-16 (Choir)

---

# 7. PACKET FORMAT

```
[HEADER][TIMESTAMP][STREAM_ID][SEQ][OPUS_PAYLOAD]
```

## Transport

- Default: UDP Unicast
- Optional: Multicast

---

# 8. CLIENT ARCHITECTURE

## Pipeline

- UDP Receiver
- Jitter Buffer
- Opus Decoder
- Audio Mixer
- Output Engine

## Features

- Multi-stream mixing
- Priority-based ducking
- Push-to-talk comms

---

# 9. CONTROL PLANE API

## Core Entities

- Streams
- Sources (WING 48ch)
- Clients
- Comms Groups
- Recording Policies

## Example Stream API

```json
POST /streams
{
  "name": "Main Service",
  "channels": [1,2],
  "codec": "opus",
  "bitrate": 64000
}
```

---

# 10. EVENT SCHEMA

## Standard Format

```json
{
  "event": "STREAM_STARTED",
  "timestamp": 123456789,
  "source": "audio_engine",
  "data": {}
}
```

## Key Events

- STREAM_STARTED
- CLIENT_CONNECTED
- USB_CONNECTED
- RECORDING_STARTED
- LATENCY_WARNING

---

# 11. RECORDING SYSTEM

## Features

- 48-channel WAV recording
- Per-event file segmentation
- Configurable naming templates

## Example Path

```
/2026/07/02/CH01 - Vocals.wav
```

---

# 12. BOOT SEQUENCE

1. Proxmox boots
2. Network VLANs initialize
3. Storage mounts
4. Control Plane starts
5. Audio Engine waits for USB
6. WING detected
7. Streams initialized
8. Clients connect
9. Recording begins

---

# 13. USB WING HANDLING

- Persistent ALSA mapping required
- Hotplug detection supported
- Auto-rebind on reconnect

---

# 14. QUALITY OF SERVICE

## Priority Levels

- 0: Broadcast audio
- 1: Staff comms
- 2: Cue system
- 3: Emergency override

---

# 15. HARDWARE REQUIREMENTS

## Server

- Multi-core CPU (8+ cores recommended)
- 32–64GB RAM
- NVMe SSD (high endurance)

## Network

- Managed switch (VLAN + QoS)
- WiFi 6 or 6E APs

## Audio

- Behringer WING (48ch USB)

## Power

- UPS for server + switch + APs

---

# 16. FAILURE MODEL

| Component     | Failure Impact     |
|---------------|--------------------|
| Audio Engine  | Broadcast stops    |
| Recording VM  | Recording stops    |
| Control Plane | Config/UI down     |
| Network       | Clients disconnect |

---

# 17. DEPLOYMENT NOTES

- Always isolate Audio Engine CPU cores
- Never share USB device between containers
- Use VLAN for all audio traffic
- Prefer unicast over multicast initially
- Use NVMe for recording only

---

# END OF IMPLEMENTATION PACKAGE