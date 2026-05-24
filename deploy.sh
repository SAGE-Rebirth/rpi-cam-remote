#!/bin/bash
# =============================================================
#  RPi IMX500 Camera Stream — Full Setup Installer
#  Installs: MediaMTX, systemd services, cam-ctrl tool
#  Run on the Pi: sudo bash deploy.sh
# =============================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }

# ─── Must run as root ────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo bash deploy.sh"

# ─── Config (edit these if needed) ───────────────────────────
CAMERA_USER="${SUDO_USER:-pi}"
STREAM_WIDTH=640
STREAM_HEIGHT=480
STREAM_FPS=30
STREAM_BITRATE=2500000
STREAM_PATH="cam"

# Object detection AI preset — comment the next line to disable AI post-processing
# POST_PROCESS_FILE="/usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json"

# Build optional rpicam-vid args (empty when POST_PROCESS_FILE is commented out)
if [[ -n "${POST_PROCESS_FILE:-}" ]]; then
    RPICAM_EXTRA_ARGS="--post-process-file ${POST_PROCESS_FILE}"
else
    RPICAM_EXTRA_ARGS=""
fi

hr
echo -e "${CYAN}  RPi IMX500 Camera Stream Setup${NC}"
hr

# ─── Step 1: Detect architecture ─────────────────────────────
log "Detecting architecture..."
case "$(uname -m)" in
    aarch64) MEDIAMTX_ARCH="linux_arm64" ;;
    armv7*)  MEDIAMTX_ARCH="linux_armv7" ;;
    armv6*)  MEDIAMTX_ARCH="linux_armv6" ;;
    x86_64)  MEDIAMTX_ARCH="linux_amd64" ;;
    *)       err "Unsupported arch: $(uname -m)" ;;
esac
info "Architecture: $(uname -m) → MediaMTX build: $MEDIAMTX_ARCH"

# ─── Step 2: Install system dependencies ─────────────────────
log "Installing dependencies..."
apt-get update -qq
apt-get install -y -q ffmpeg curl wget python3

# ─── Step 3: Install MediaMTX standalone binary (official method) ────────────
# Ref: https://mediamtx.org/docs/kickoff/install
if command -v mediamtx &>/dev/null; then
    warn "MediaMTX already installed: $(mediamtx --version 2>&1 | head -1) — skipping."
else
    log "Resolving latest MediaMTX version..."
    # Read the Location header from the /releases/latest redirect — no API rate limits
    MEDIAMTX_VERSION=$(wget -q --server-response --spider \
        "https://github.com/bluenviron/mediamtx/releases/latest" 2>&1 \
      | grep -i "Location:" \
      | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' \
      | tail -1 | tr -d '\r\n')

    [[ -z "$MEDIAMTX_VERSION" ]] && err "Could not resolve MediaMTX version. Check internet."
    info "Latest MediaMTX version: $MEDIAMTX_VERSION"

    TARBALL="mediamtx_${MEDIAMTX_VERSION}_${MEDIAMTX_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/${TARBALL}"
    TARBALL_TMP="/tmp/${TARBALL}"

    log "Downloading ${TARBALL}..."
    wget --show-progress -q -O "$TARBALL_TMP" "$DOWNLOAD_URL" \
      || err "Download failed. URL: $DOWNLOAD_URL"

    # Sanity check — a valid binary tarball must be several MB
    TARBALL_SIZE=$(stat -c%s "$TARBALL_TMP" 2>/dev/null || echo 0)
    [[ "$TARBALL_SIZE" -lt 1048576 ]] && \
      err "Downloaded file is only ${TARBALL_SIZE} bytes — bad URL or redirect. Aborting."

    log "Extracting and installing MediaMTX binary..."
    tar -xzf "$TARBALL_TMP" -C /tmp mediamtx
    install -m 755 /tmp/mediamtx /usr/local/bin/mediamtx
    rm -f "$TARBALL_TMP" /tmp/mediamtx

    log "MediaMTX installed: $(mediamtx --version 2>&1 | head -1)"
fi

# ─── Step 4: MediaMTX config ─────────────────────────────────
log "Writing MediaMTX config → /etc/mediamtx/mediamtx.yml"
mkdir -p /etc/mediamtx
cat > /etc/mediamtx/mediamtx.yml << 'EOF'
# ─────────────────────────────────────────────────────────────
#  MediaMTX — RPi IMX500 Camera Stream
#  Docs: https://github.com/bluenviron/mediamtx
# ─────────────────────────────────────────────────────────────

logLevel: info
logDestinations: [stdout]

# ── Protocol listeners ────────────────────────────────────────
rtspAddress:    :8554     # RTSP  → ffplay, VLC, mpv
rtmpAddress:    :1935     # RTMP  (not used, kept available)
hlsAddress:     :8888     # HLS   → browser http://pi:8888/cam
webrtcAddress:  :8889     # WebRTC→ browser http://pi:8889/cam

# ── REST API (cam-ctrl uses this) ─────────────────────────────
api: yes
apiAddress: :9997
metrics: no

# ── HLS low-latency tuning ────────────────────────────────────
hlsVariant:        lowLatency
hlsSegmentCount:   7
hlsSegmentDuration: 500ms
hlsPartDuration:   200ms

# ── Stream paths ──────────────────────────────────────────────
paths:
  cam:
    # ffmpeg pushes RTSP here; MediaMTX re-serves all protocols
    source: publisher
    sourceOnDemand: no
    record: no
EOF

# ─── Step 5: Camera stream wrapper script ────────────────────
log "Writing camera stream script → /usr/local/bin/camera-stream.sh"
cat > /usr/local/bin/camera-stream.sh << SCRIPT_EOF
#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  camera-stream.sh — rpicam-vid → ffmpeg → MediaMTX (RTSP)
#  Called by camera-stream.service. Do not run directly.
# ─────────────────────────────────────────────────────────────

# Kill both sides of the pipe cleanly on SIGTERM/SIGINT
trap 'kill 0' SIGTERM SIGINT SIGQUIT ERR

echo "[camera-stream] Starting IMX500 capture pipeline..."

rpicam-vid \\
    -t 0 \\
    --nopreview \\
    --codec h264 \\
    --libav-format h264 \\
    --libav-video-codec-opts "preset=ultrafast;tune=zerolatency" \\
    --profile baseline \\
    --intra ${STREAM_FPS} \\
    --inline \\
    --flush \\
    --width ${STREAM_WIDTH} \\
    --height ${STREAM_HEIGHT} \\
    --framerate ${STREAM_FPS} \\
    --bitrate ${STREAM_BITRATE} \\
    ${RPICAM_EXTRA_ARGS} \\
    -o - | \\
ffmpeg \\
    -hide_banner \\
    -loglevel warning \\
    -fflags +nobuffer+flush_packets \\
    -flags low_delay \\
    -f h264 \\
    -i pipe:0 \\
    -c:v copy \\
    -f rtsp \\
    -rtsp_transport tcp \\
    rtsp://127.0.0.1:8554/${STREAM_PATH}

wait
SCRIPT_EOF
chmod +x /usr/local/bin/camera-stream.sh

# ─── Step 6: systemd — mediamtx.service ──────────────────────
log "Writing mediamtx.service..."
cat > /etc/systemd/system/mediamtx.service << 'EOF'
[Unit]
Description=MediaMTX Streaming Server
Documentation=https://github.com/bluenviron/mediamtx
# Wait for network before starting
After=network-online.target
Wants=network-online.target
# Unlimited restart attempts — always recover
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml

# ── Resilience ────────────────────────────────────────────────
Restart=always
RestartSec=5
TimeoutStopSec=10
LimitNOFILE=65536

# ── Logging (view with: journalctl -u mediamtx -f) ───────────
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

[Install]
WantedBy=multi-user.target
EOF

# ─── Step 7: systemd — camera-stream.service ─────────────────
log "Writing camera-stream.service..."
cat > /etc/systemd/system/camera-stream.service << CAMSVC_EOF
[Unit]
Description=RPi IMX500 Camera Stream (rpicam-vid + ffmpeg → MediaMTX)
# Must start AFTER mediamtx and stop BEFORE it
After=mediamtx.service network-online.target
Requires=mediamtx.service
Wants=network-online.target
# Unlimited restart attempts — always recover
StartLimitIntervalSec=0

[Service]
Type=simple
User=${CAMERA_USER}
SupplementaryGroups=video

# Brief pause so MediaMTX RTSP listener is fully ready
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/camera-stream.sh

# ── Resilience ────────────────────────────────────────────────
# Covers: crashes, OOM kills, power restore, rpicam-vid hung, ffmpeg error
Restart=always
RestartSec=5
TimeoutStopSec=15
# Kill entire cgroup (rpicam-vid + ffmpeg child processes)
KillMode=control-group

# ── Logging (view with: journalctl -u camera-stream -f) ──────
StandardOutput=journal
StandardError=journal
SyslogIdentifier=camera-stream

[Install]
WantedBy=multi-user.target
CAMSVC_EOF

# ─── Step 8: cam-ctrl management tool ────────────────────────
log "Writing cam-ctrl → /usr/local/bin/cam-ctrl"
cat > /usr/local/bin/cam-ctrl << 'CTRL_EOF'
#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  cam-ctrl — IMX500 stream remote management tool
#  Usage: cam-ctrl <command>
#  SSH into Pi via Tailscale, then run this tool.
# ─────────────────────────────────────────────────────────────

CAM_SVC="camera-stream"
MTX_SVC="mediamtx"
MTX_API="http://localhost:9997"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; }
info() { echo -e "${CYAN}  →${NC} $*"; }
hr()   { echo -e "${BLUE}  ────────────────────────────────────${NC}"; }

need_root() { [[ $EUID -ne 0 ]] && { echo -e "${RED}Needs sudo${NC}"; exit 1; }; }

svc_state() {
    if systemctl is-active --quiet "$1"; then
        echo -e "${GREEN}running${NC}"
    else
        echo -e "${RED}stopped${NC}"
    fi
}

svc_uptime() {
    local ts
    ts=$(systemctl show "$1" --property=ActiveEnterTimestamp --value 2>/dev/null)
    [[ -n "$ts" ]] && echo "(since $ts)" || echo ""
}

# ── Commands ──────────────────────────────────────────────────

cmd_start() {
    need_root
    info "Starting MediaMTX..."
    systemctl start $MTX_SVC
    sleep 3
    info "Starting camera stream..."
    systemctl start $CAM_SVC
    sleep 2
    echo; cmd_status
}

cmd_stop() {
    need_root
    info "Stopping camera stream..."
    systemctl stop $CAM_SVC
    info "Stopping MediaMTX..."
    systemctl stop $MTX_SVC
    ok "All services stopped."
}

cmd_restart() {
    need_root
    info "Restarting camera stream (MediaMTX stays up)..."
    systemctl restart $CAM_SVC
    sleep 2
    echo; cmd_status
}

cmd_restart_all() {
    need_root
    info "Restarting all services..."
    systemctl restart $MTX_SVC
    sleep 3
    systemctl restart $CAM_SVC
    sleep 2
    echo; cmd_status
}

cmd_status() {
    hr
    echo -e "  MediaMTX        $(svc_state $MTX_SVC) $(svc_uptime $MTX_SVC)"
    echo -e "  Camera stream   $(svc_state $CAM_SVC) $(svc_uptime $CAM_SVC)"
    hr
    # Show recent errors if any service is down
    for svc in $MTX_SVC $CAM_SVC; do
        if ! systemctl is-active --quiet $svc; then
            echo -e "${YELLOW}  Last $svc log:${NC}"
            journalctl -u "$svc" -n 8 --no-pager -o short 2>/dev/null | sed 's/^/    /'
        fi
    done
}

cmd_logs() {
    echo -e "${BLUE}  === MediaMTX (last 40 lines) ===${NC}"
    journalctl -u $MTX_SVC -n 40 --no-pager
    echo
    echo -e "${BLUE}  === Camera stream (last 40 lines) ===${NC}"
    journalctl -u $CAM_SVC -n 40 --no-pager
}

cmd_watch() {
    echo -e "${CYAN}  Following live logs — Ctrl+C to stop${NC}"
    journalctl -u $CAM_SVC -u $MTX_SVC -f --no-pager
}

cmd_url() {
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "tailscale-not-connected")
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    hr
    echo -e "  ${CYAN}Local network${NC}"
    echo "    RTSP    →  rtsp://$LOCAL_IP:8554/cam"
    echo "    HLS     →  http://$LOCAL_IP:8888/cam"
    echo "    WebRTC  →  http://$LOCAL_IP:8889/cam"
    hr
    echo -e "  ${CYAN}Remote via Tailscale${NC}"
    echo "    RTSP    →  rtsp://$TS_IP:8554/cam"
    echo "    HLS     →  http://$TS_IP:8888/cam"
    echo "    WebRTC  →  http://$TS_IP:8889/cam"
    echo "    API     →  http://$TS_IP:9997"
    hr
    echo -e "  ${CYAN}Mac ffplay command${NC}"
    echo "    ffplay -fflags nobuffer -flags low_delay -framedrop -vf setpts=0 rtsp://$TS_IP:8554/cam"
    hr
}

cmd_test() {
    hr
    echo -e "  ${CYAN}Service health${NC}"
    for svc in $MTX_SVC $CAM_SVC; do
        if systemctl is-active --quiet $svc; then
            ok "$svc is running"
        else
            fail "$svc is NOT running"
        fi
    done

    echo
    echo -e "  ${CYAN}MediaMTX API${NC}"
    if curl -sf --max-time 3 "$MTX_API/v3/paths/list" > /dev/null 2>&1; then
        ok "API is reachable at $MTX_API"
        # Parse active paths
        RESULT=$(curl -sf "$MTX_API/v3/paths/list" 2>/dev/null | \
            python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('items', [])
    ready = [i['name'] for i in items if i.get('ready', False)]
    print(f'{len(ready)} ready path(s): {ready}')
except:
    print('could not parse response')
" 2>/dev/null)
        ok "$RESULT"
    else
        fail "API unreachable — is MediaMTX running?"
    fi

    echo
    echo -e "  ${CYAN}Tailscale${NC}"
    if command -v tailscale &>/dev/null; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
        TS_STATUS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('BackendState','unknown'))" 2>/dev/null || echo "unknown")
        if [[ -n "$TS_IP" ]]; then
            ok "Tailscale connected — IP: $TS_IP (state: $TS_STATUS)"
        else
            fail "Tailscale not connected (state: $TS_STATUS)"
        fi
    else
        fail "Tailscale not installed"
    fi
    hr
}

cmd_enable() {
    need_root
    systemctl enable $MTX_SVC $CAM_SVC
    ok "Services enabled — will auto-start on every boot."
}

cmd_disable() {
    need_root
    systemctl disable $MTX_SVC $CAM_SVC
    echo -e "${YELLOW}  Auto-start disabled. Services will NOT start on boot.${NC}"
}

cmd_config() {
    echo -e "${CYAN}  Opening MediaMTX config in editor...${NC}"
    "${EDITOR:-nano}" /etc/mediamtx/mediamtx.yml
    echo -e "${CYAN}  Restart services to apply changes:${NC}"
    echo "    sudo cam-ctrl restart-all"
}

cmd_help() {
    echo
    echo -e "${CYAN}  cam-ctrl — IMX500 stream management${NC}"
    echo
    echo "  Service control"
    echo "    start          Start MediaMTX + camera stream"
    echo "    stop           Stop all services"
    echo "    restart        Restart camera stream only (MediaMTX stays up)"
    echo "    restart-all    Restart everything (MediaMTX + camera)"
    echo
    echo "  Monitoring"
    echo "    status         Show running status with uptime"
    echo "    logs           Last 40 log lines from both services"
    echo "    watch          Follow live logs (Ctrl+C to exit)"
    echo "    test           Health check: services + API + Tailscale"
    echo
    echo "  Info"
    echo "    url            Print all stream URLs (local + Tailscale)"
    echo "    config         Edit mediamtx.yml config"
    echo
    echo "  Boot management"
    echo "    enable         Enable auto-start on boot"
    echo "    disable        Disable auto-start on boot"
    echo
}

# ── Dispatch ──────────────────────────────────────────────────
case "${1:-status}" in
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
    restart-all) cmd_restart_all ;;
    status)      cmd_status ;;
    logs)        cmd_logs ;;
    watch)       cmd_watch ;;
    url)         cmd_url ;;
    test)        cmd_test ;;
    enable)      cmd_enable ;;
    disable)     cmd_disable ;;
    config)      cmd_config ;;
    help|--help) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        cmd_help
        exit 1
        ;;
esac
CTRL_EOF
chmod +x /usr/local/bin/cam-ctrl

# ─── Step 9: Enable and start everything ─────────────────────
log "Reloading systemd daemon..."
systemctl daemon-reload

log "Enabling services for auto-start on boot..."
systemctl enable mediamtx.service camera-stream.service

log "Restarting MediaMTX (picks up config changes)..."
systemctl restart mediamtx.service
sleep 4

log "Restarting camera stream (picks up script changes)..."
systemctl restart camera-stream.service
sleep 4

# ─── Step 10: Final report ────────────────────────────────────
hr
echo -e "${CYAN}  Setup complete!${NC}"
hr
cam-ctrl status
echo
cam-ctrl url
hr

echo -e "${CYAN}  Tailscale (if not installed yet):${NC}"
echo "    curl -fsSL https://tailscale.com/install.sh | sh"
echo "    sudo tailscale up"
hr
echo -e "${CYAN}  cam-ctrl commands:${NC}"
echo "    sudo cam-ctrl start | stop | restart | restart-all"
echo "         cam-ctrl status | logs | watch | url | test | config"
hr