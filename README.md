# @ludens-community/driver-switch2

Real-hardware Nintendo Switch / Switch 2 driver for Ludens Baseware. This standalone package implements the `DriverRegistration` (`id: "switch2"`) and bridges two decoupled local endpoints without any runtime import from the Ludens host repository:

1. **Gamepad Bridge (`:18765`)** — Raspberry Pi 5 running `pcble2gamepad` (Bluetooth Pro Controller emulation), auto-tunneled over SSH (`127.0.0.1:18765 -> 127.0.0.1:8765`) with automatic Bluetooth `waiting` recovery.
2. **HDMI Capture Service (`:18766`)** — Native macOS Swift helper (`switch2-capture`) driving USB UVC HDMI capture cards (e.g., Hagibis, UGREEN, Elgato, AVerMedia) in a persistent `--headless` daemon, paired with an optional decoupled `--preview` desktop client window that reconnects automatically across capture restarts.

Importing the package only describes the driver registration; it never touches hardware, opens SSH tunnels, or starts capture processes until `load()` is invoked.

---

## Architecture Topology

```text
┌──────────────────────┐       Bluetooth HID        ┌─────────────────────────────────────────┐
│                      │ ◄───────────────────────── │  Raspberry Pi 5 (ludens-pi.local)       │
│  Nintendo Switch 2   │                            │  ludens-wireless-controller (:8765)     │
│                      │ ───────── HDMI ──────────► └────────────────────▲────────────────────┘
└──────────────────────┘               │                                 │ SSH -L 18765:127.0.0.1:8765
                                       ▼                                 │
                        ┌──────────────────────────────┐    ┌────────────┴────────────────────┐
                        │  USB UVC HDMI Capture Card   │    │  Ludens Baseware (macOS Host)   │
                        │  (Hagibis / UGREEN / etc.)   │    │  @ludens-community/driver-switch2│
                        └──────────────┬───────────────┘    └────────────┬────────────────────┘
                                       │ AVFoundation (App Nap disabled) │ HTTP /capture (with retry)
                                       ▼                                 ▼
                        ┌──────────────────────────────────────────────────────┐
                        │  switch2-capture --headless (127.0.0.1:18766)        │
                        │  GET /status · GET /health · GET /capture · /stream  │
                        └──────────────────────────▲───────────────────────────┘
                                                   │ MJPEG /stream (500ms auto-reconnect)
                                                   │
                        ┌──────────────────────────┴───────────────────────────┐
                        │  switch2-capture --preview (Desktop Preview Window)  │
                        │  Closing/reopening window never interrupts AI capture│
                        └──────────────────────────────────────────────────────┘
```

### Why Dual-Process Capture + Preview?
- **Lock-screen & Space resilience**: `switch2-capture` holds a persistent `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` token so macOS App Nap never throttles `AVCaptureSession` when the screen locks or windows are occluded.
- **Zero-downtime UI lifecycle**: Baseware always launches `switch2-capture --headless` (`NSApplication.ActivationPolicy.prohibited`) so background restarts never steal desktop focus, and closing the `--preview` desktop window never terminates the HDMI capture daemon.
- **Smart attach & exclusive port binding**: `NWListener` binds `:18766` without `allowLocalEndpointReuse`, preventing silent duplicate instances from fighting over the UVC device. Launching `switch2-capture` without flags automatically probes `http://127.0.0.1:18766/status` and attaches in pure `--preview` client mode if a healthy daemon is already running.
- **Transient capture retry**: `screen.capture` retries transient network errors and `HTTP 502/503/504` responses (up to 2 retries with `250ms` backoff while respecting `AbortSignal`), riding through sub-second capture daemon restarts cleanly.

---

## Install in Ludens

Use a reviewed commit SHA as `<revision>`:

```sh
baseware driver discover --package 'github:luokerenx4/ludens-switch-machine-driver#<revision>'
rsa init --driver switch2 \
  --driver-package 'github:luokerenx4/ludens-switch-machine-driver#<revision>'
rsa up --dry-run
rsa up
```

For local workspace development:

```sh
rsa init --driver switch2 \
  --driver-package file:/absolute/path/to/ludens-switch2-driver
```

---

## Build & Run the Capture Service

Requires macOS 14+ on Apple Silicon or Intel with Xcode Command Line Tools (`swiftc`) and [Bun](https://bun.sh).

```sh
bun install --frozen-lockfile

# Compile native/build/switch2-capture
bun run capture:build

# Run background-safe headless capture daemon on 127.0.0.1:18766
bun run capture:headless

# Open decoupled desktop preview client window (auto-reconnects on stream loss)
bun run capture:preview
```

### `switch2-capture` CLI Options

| Flag | Description | Default |
| --- | --- | --- |
| `--headless` | Run UVC capture + HTTP server only (`ActivationPolicy.prohibited`, no GUI window). Exits non-zero immediately on port conflict. | `false` (unless env set) |
| `--preview` | Run pure desktop preview window streaming from an existing capture server without touching UVC hardware. | Auto-enabled when `:18766` is already healthy |
| `--url <url>` | Base URL of the capture daemon for `--preview` mode. | `http://127.0.0.1:<port>` |
| `--port <port>` | Loopback HTTP port for `--headless` server (or default target port for `--preview`). | `18766` |
| `--device <name>` | Preferred UVC capture card name, model, or unique ID (`auto` scores external UVC HDMI cards and ignores Continuity/Apple cameras). | `auto` |
| `--mode <mode>` | Capture resolution and frame rate (`1920x1080@60`, `1080p60`, `1280x720@60`, `720p60`, `2k60`, `4k60`, etc.). | `1280x720@60` |
| `--help`, `-h` | Print CLI usage and exit. | — |

### `switch2-capture` HTTP Endpoints

- `GET /status` & `GET /health` (also supports `HEAD`): JSON health/telemetry snapshot (`ok`, `connected`, `headless`, `mode`, `device`, `modelID`, `supportedModes`, `width`, `height`, `fps`, `frameSequence`, `capturedAtMs`, `streamClients`, `pid`).
- `GET /capture?format=jpeg|png&quality=0.2..1.0`: Latest captured frame with `X-Frame-Sequence`, `X-Frame-Width`, and `X-Frame-Height` headers (`503` if no frame is available within 2s).
- `GET /stream?fps=1..60&quality=0.3..0.95`: `multipart/x-mixed-replace; boundary=frame` live MJPEG stream consumed by `--preview` (shares per-frame JPEG cache across clients and cleans up automatically on disconnect).

---

## Environment Variables

| Variable | Meaning | Default |
| --- | --- | --- |
| `LUDENS_SWITCH2_PORT` | Local loopback port for the Pi gamepad bridge | `18765` |
| `LUDENS_SWITCH2_PI_URL` | Full HTTP base URL override for the Pi gamepad bridge | `http://127.0.0.1:<port>` |
| `LUDENS_SWITCH2_SSH_TARGET` | SSH destination used for auto-tunneling and `systemctl` self-healing | `grand@ludens-pi.local` |
| `LUDENS_SWITCH2_REMOTE_PORT` | Remote loopback port of `ludens-wireless-controller` on the Pi | `8765` |
| `LUDENS_SWITCH2_CAPTURE_URL` | Full HTTP base URL override for `switch2-capture` (disables auto-spawn unless `spawnCapture: true`) | `http://127.0.0.1:<capturePort>` |
| `LUDENS_SWITCH2_CAPTURE_PORT` | Local loopback port for `switch2-capture` | `18766` |
| `LUDENS_SWITCH2_CAPTURE_DEVICE` | Preferred UVC capture card substring or ID | `auto` |
| `LUDENS_SWITCH2_CAPTURE_MODE` | Preferred capture mode (e.g., `1920x1080@60`) | `1280x720@60` |
| `LUDENS_SWITCH2_CAPTURE_HEADLESS` | Set to `1` to force `--headless` daemon mode | unset |
| `LUDENS_SWITCH2_CAPTURE_PREVIEW` | Set to `1` to force `--preview` client window mode | unset |

---

## Device Capabilities

- `pad.play` / `pad.state` / `pad.status` / `pad.wait` / `pad.cancel` / `pad.release`:
  - Full 18-button Switch Pro Controller bitmask (`A`, `B`, `X`, `Y`, `L`, `R`, `ZL`, `ZR`, `LSTICK`, `RSTICK`, `PLUS`, `MINUS`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `HOME`, `CAPTURE`) and calibrated 12-bit dual analog sticks (`LX`, `LY`, `RX`, `RY` in `-1..1`).
  - Compiles multi-channel timelines (`>= 16ms` state transitions) and anchors span deadlines to wall-clock time while refreshing `POST /input` every `100ms` so the Pi 500ms watchdog stays alive during holds.
  - Automatically restarts `ludens-wireless-controller` if Bluetooth drops back to `waiting` (e.g., during Switch *Change Grip/Order* pairing transitions).
- `screen.capture`:
  - Captures the latest HDMI frame as `jpeg` (default) or `png` after an optional `delayMs`, returning `sourceSequence`, dimensions, and timing metadata. Does not require pad ownership (`requiresControl: false`).

---

## Development & Verification

```sh
bun run typecheck
bun test
bun run scripts:check
bun run capture:build
```

Unit tests run completely offline against ephemeral loopback mock Pi and capture servers (plus temporary child-process fixtures verifying `--headless` daemon launch and `/capture` retry behavior) without touching `:18765`, `:18766`, SSH, or UVC hardware.
