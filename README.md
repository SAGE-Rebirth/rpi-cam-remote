# RPi IMX500 Remote Camera Stream

A production-ready, self-healing live video streaming setup using a **Raspberry Pi** with the **Sony IMX500 AI camera module**, streamed remotely over **Tailscale VPN** via **MediaMTX** — accessible from anywhere in the world without port forwarding or router configuration.

---

## Architecture

```
Sony IMX500 Camera
       │
       ▼
  rpicam-vid  ──── H.264 capture + AI post-processing (MobileNet SSD)
       │ stdout pipe
       ▼
    ffmpeg  ──── Re-wraps H.264 → RTSP
       │ RTSP push (TCP, localhost:8554)
       ▼
   MediaMTX  ──── Streaming server (RTSP · HLS · WebRTC · REST API)
       │
       ▼
   Tailscale  ──── Encrypted VPN mesh (no port forwarding needed)
       │
       ▼
Remote Clients
  ├── ffplay / VLC  →  rtsp://100.x.x.x:8554/cam
  ├── Browser HLS   →  http://100.x.x.x:8888/cam
  └── SSH control   →  ssh user@100.x.x.x → cam-ctrl
```

All services run as **systemd units** — they start on boot, restart on crash, and recover automatically after power failure.

---

## Features

- **Live H.264 stream** from Sony IMX500 with AI object detection (MobileNet SSD)
- **Sub-second latency over WebRTC** (~200–350 ms end-to-end over Tailscale) — tuned with `tune=zerolatency` to eliminate libx264's lookahead buffer
- **Multiple protocols** — RTSP, HLS, WebRTC served simultaneously from one source
- **Remote access** via Tailscale VPN — works from any network, any country
- **No port forwarding** — Tailscale handles NAT traversal automatically
- **Self-healing services** — systemd restarts both services indefinitely on any failure
- **Boot-persistent** — services start automatically on every boot and power restore
- **Management tool** — `cam-ctrl` CLI for start/stop/restart/status/logs from SSH
- **REST API** — MediaMTX exposes a control API on port 9997

---

## Quick Start

On a fresh Pi, two commands get everything running:

```bash
sudo bash tailscale-setup.sh    # joins the Pi to your tailnet
sudo bash deploy.sh             # installs MediaMTX, services, cam-ctrl
```

Both scripts are idempotent — safe to re-run after edits.

---

## Hardware Requirements

- Raspberry Pi 4 or 5 (aarch64)
- Sony IMX500 AI Camera Module (official Raspberry Pi camera)
- SD card with Raspberry Pi OS (64-bit, Debian Bookworm or later)
- Internet connection on the Pi (for initial setup)

---

## Software Stack

| Component | Role | Version |
|---|---|---|
| `rpicam-vid` | Camera capture + AI inference | Bundled with Pi OS |
| `ffmpeg` | MJPEG → RTSP transcoding | System apt package |
| `MediaMTX` | Multi-protocol streaming server | Latest (auto-detected) |
| `Tailscale` | Encrypted VPN mesh for remote access | Latest |
| `systemd` | Service management, auto-restart | System |

---

## Repo Layout

The files you copy to the Pi:

```
tailscale-setup.sh    ← One-command Tailscale install + join (run first)
wifi-priority.sh      ← Pin a hotspot SSID as the priority network + powersave off
deploy.sh             ← Full installer (embeds everything below)
diagnose.sh           ← Read-only health report (no sudo required)
uninstall.sh          ← Removes everything deploy.sh installed
cam-ctrl              ← Reference copy of the management CLI
camera-stream.sh      ← Reference copy of the camera pipeline wrapper
camera-stream.service ← Reference copy of the camera systemd unit
mediamtx.yml          ← Reference copy of MediaMTX config
mediamtx.service      ← Reference copy of the MediaMTX systemd unit
README.md / SETUP.md  ← This documentation
```

## Installed File Layout

After running `deploy.sh`, files are installed to these system locations:

```
/usr/local/bin/mediamtx           ← MediaMTX server binary
/usr/local/bin/camera-stream.sh   ← Camera pipeline wrapper script
/usr/local/bin/cam-ctrl           ← Management CLI tool

/etc/mediamtx/mediamtx.yml        ← MediaMTX configuration

/etc/systemd/system/mediamtx.service        ← MediaMTX systemd unit
/etc/systemd/system/camera-stream.service   ← Camera stream systemd unit
```

---

## Stream URLs

Replace `100.x.x.x` with your Pi's Tailscale IP (run `cam-ctrl url` to see it).

| Protocol | URL | Best for |
|---|---|---|
| RTSP | `rtsp://100.x.x.x:8554/cam` | ffplay, VLC, mpv — lowest latency desktop apps |
| WebRTC | `http://100.x.x.x:8889/cam` | Browser, real-time (sub-second latency) |
| HLS | `http://100.x.x.x:8888/cam` | Browser fallback, any device, no plugin needed |
| REST API | `http://100.x.x.x:9997` | Health checks, path management |

All three viewer protocols play the same H.264 stream simultaneously — no extra command on the Pi.

### Mac ffplay command

```bash
ffplay -fflags nobuffer -flags low_delay -framedrop \
  -rtsp_transport tcp \
  -vf setpts=0 \
  rtsp://100.x.x.x:8554/cam
```

---

## cam-ctrl Reference

`cam-ctrl` is installed at `/usr/local/bin/cam-ctrl` and is available system-wide. SSH into the Pi via Tailscale and use it to manage the stream remotely.

### Service control (requires sudo)

```bash
sudo cam-ctrl start          # Start MediaMTX + camera stream
sudo cam-ctrl stop           # Stop all services
sudo cam-ctrl restart        # Restart camera only (MediaMTX stays up — faster)
sudo cam-ctrl restart-all    # Restart everything from scratch
sudo cam-ctrl enable         # Enable auto-start on boot
sudo cam-ctrl disable        # Disable auto-start on boot
sudo cam-ctrl config         # Edit /etc/mediamtx/mediamtx.yml in-place
```

### Monitoring (no sudo needed)

```bash
cam-ctrl status      # Running state of both services with uptime
cam-ctrl logs        # Last 40 log lines from each service
cam-ctrl watch       # Follow live logs in real time (Ctrl+C to exit)
cam-ctrl test        # Full health check: services + MediaMTX API + Tailscale
cam-ctrl url         # Print all stream URLs with current Tailscale IP
```

---

## Systemd Services

### mediamtx.service

```
After=network-online.target
Restart=always
RestartSec=5
StartLimitIntervalSec=0    ← unlimited restart attempts
```

### camera-stream.service

```
After=mediamtx.service     ← waits for MediaMTX before starting
Requires=mediamtx.service  ← stops if MediaMTX stops
Restart=always
RestartSec=5
StartLimitIntervalSec=0    ← unlimited restart attempts
KillMode=control-group     ← kills both rpicam-vid and ffmpeg cleanly
```

### Useful systemd commands

```bash
# View detailed service status
systemctl status mediamtx
systemctl status camera-stream

# View logs
journalctl -u mediamtx -f
journalctl -u camera-stream -f

# Both services together
journalctl -u mediamtx -u camera-stream -f
```

---

## Edge Cases Handled

| Scenario | Behaviour |
|---|---|
| Pi boots up | Both services start automatically |
| Pi reboots | Same as boot — systemd restores everything |
| Power failure & restore | Both services restart as soon as OS is up |
| rpicam-vid crashes | `camera-stream.service` restarts within 5 seconds |
| ffmpeg crashes | Same — the pipe exits, service restarts |
| MediaMTX crashes | Restarts itself; camera-stream then reconnects |
| Pipe hangs (zombie process) | `KillMode=control-group` kills entire cgroup |
| Tailscale disconnects | Stream continues locally; Tailscale auto-reconnects |
| Internet loss | No effect on local streaming; remote access resumes when internet returns |
| Service restart storm | `StartLimitIntervalSec=0` — systemd never gives up retrying |

---

## Camera Configuration

The camera pipeline is configured in `/usr/local/bin/camera-stream.sh`.

Default settings:

```
Resolution : 640 × 480
Framerate  : 30 fps
Bitrate    : 2,500,000 bps (2.5 Mbps)
Codec      : H.264 (baseline profile, 1s GOP, inline SPS/PPS, low-latency flush)
AI model   : MobileNet SSD (imx500_mobilenet_ssd.json)
```

To change resolution, bitrate or framerate:

```bash
sudo nano /usr/local/bin/camera-stream.sh
sudo cam-ctrl restart
```

To reduce bandwidth over Tailscale, lower the bitrate. H.264 is efficient — 600–1000 kbps is usually plenty at 640×480:
```
--bitrate 800000
```

---

## MediaMTX Configuration

Config file: `/etc/mediamtx/mediamtx.yml`

```bash
sudo cam-ctrl config        # opens in editor
sudo cam-ctrl restart-all   # apply changes
```

Key ports:

| Port | Protocol |
|---|---|
| 8554 | RTSP |
| 8888 | HLS |
| 8889 | WebRTC |
| 9997 | REST API |
| 1935 | RTMP (available, not used) |

---

## Wi-Fi Reliability (optional but recommended for hotspot use)

If the Pi tethers to a phone hotspot, two NetworkManager defaults will bite you: Wi-Fi power saving causes slow / dropped reconnects, and other saved networks may auto-connect ahead of the hotspot. `wifi-priority.sh` fixes both in one shot.

```bash
sudo bash wifi-priority.sh                  # defaults to "OnePlus 12"
sudo bash wifi-priority.sh "MyHotspot"      # custom SSID
sudo bash wifi-priority.sh "MyHotspot" --no-reboot
```

What it does:
- Writes `/etc/NetworkManager/conf.d/wifi-powersave-off.conf` (`wifi.powersave = 2`) to disable Wi-Fi power management permanently and globally.
- Disables powersave on the live `wlan0` immediately (`iw` or `iwconfig`).
- Finds every NM profile whose SSID matches (catches both `"OnePlus 12"` and `"netplan-wlan0-OnePlus 12"`-style netplan-imported profiles) and applies:
  - `connection.autoconnect yes`
  - `connection.autoconnect-priority 10`
  - `connection.autoconnect-retries 0` (forever)
  - `802-11-wireless.powersave 2`
- Reloads NetworkManager, prints verification (`iwconfig`/`iw` + the relevant `nmcli` fields), and reboots (confirms first; `--yes` skips, `--no-reboot` exits cleanly).

Idempotent — safe to re-run after changing phones / hotspot names.

---

## Diagnostics & Uninstall

**`diagnose.sh` — full health report.** Goes deeper than `cam-ctrl test`: checks Pi model, IMX500 detection, video device nodes, video/render group membership, encoder toolchain, zerolatency tune verification (looks for `Constrained Baseline` in the journal), MediaMTX paths via the REST API, Tailscale state, port listeners, and a live ffprobe of the local RTSP. Read-only — no sudo needed; exits non-zero on failure so it can also be used from scripts.

```bash
bash diagnose.sh
```

**`uninstall.sh` — clean removal.** Stops/disables both services, removes the installed binaries, scripts, systemd units, and `/etc/mediamtx/`. Asks separately before removing Tailscale or ffmpeg (since both may be used outside this project). Leaves the `rpi-cam` folder and your home directory untouched.

```bash
sudo bash uninstall.sh
# Fully scripted:
sudo bash uninstall.sh --yes --keep-tailscale --keep-ffmpeg
```

---

## Troubleshooting

**Stream times out / connection refused**
```bash
bash diagnose.sh       # full picture: services + camera + ports + API
cam-ctrl logs          # read error details
sudo cam-ctrl restart-all
```

**Dropped frames / RTP missed packets**
- Add `-rtsp_transport tcp` to your ffplay command
- Lower bitrate in `camera-stream.sh` to 800000

**Tailscale shows as not connected**
```bash
sudo tailscale status
sudo tailscale up
# Or, if Tailscale was never installed:
sudo bash tailscale-setup.sh
```

**Camera-stream keeps restarting**
```bash
journalctl -u camera-stream -n 50
# Look for rpicam-vid or ffmpeg error messages
```

**MediaMTX API unreachable**
```bash
systemctl status mediamtx
curl http://localhost:9997/v3/paths/list
```

---

## License

MIT — use freely for personal and commercial projects.