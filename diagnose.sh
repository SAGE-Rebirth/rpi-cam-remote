#!/bin/bash
# =============================================================
#  rpi-cam diagnostics — full health report
#  Run on the Pi: bash diagnose.sh
#  (sudo not required; some checks are skipped without it)
# =============================================================

# Note: no `set -e` — diagnostics must keep running through failures.

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; FAILS=$((FAILS+1)); }
warn() { echo -e "  ${YELLOW}!${NC} $*"; WARNS=$((WARNS+1)); }
info() { echo -e "  ${CYAN}→${NC} $*"; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }
section() { echo; hr; echo -e "${CYAN}  $*${NC}"; hr; }

FAILS=0
WARNS=0

# ─── Header ──────────────────────────────────────────────────
echo
hr
echo -e "${CYAN}  rpi-cam diagnostics — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
hr

# ─── System ──────────────────────────────────────────────────
section "System"
info "Host:     $(hostname)"
info "Uptime:   $(uptime -p 2>/dev/null || uptime)"
info "Arch:     $(uname -m)"
info "Kernel:   $(uname -r)"
if [[ -f /proc/device-tree/model ]]; then
    info "Model:    $(tr -d '\0' < /proc/device-tree/model)"
fi
if [[ -f /etc/os-release ]]; then
    OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    info "OS:       $OS_NAME"
fi

# Memory + disk
MEM_FREE=$(free -h | awk '/^Mem:/ {print $7 " free of " $2}')
info "Memory:   $MEM_FREE"
DISK_FREE=$(df -h / | awk 'NR==2 {print $4 " free of " $2 " (" $5 " used)"}')
info "Disk /:   $DISK_FREE"

DISK_PCT=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
if [[ "$DISK_PCT" -gt 90 ]]; then
    fail "Disk over 90% full — streaming may fail when logs/journal grow."
fi

# Throttling / undervoltage on the Pi
if command -v vcgencmd >/dev/null 2>&1; then
    THROTTLED=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')
    if [[ "$THROTTLED" == "0x0" ]]; then
        ok "Power/thermal: no throttling reported (get_throttled=0x0)"
    elif [[ -n "$THROTTLED" ]]; then
        warn "Power/thermal flag set: get_throttled=$THROTTLED  (run 'vcgencmd get_throttled' to decode)"
    fi
fi

# ─── Camera hardware ─────────────────────────────────────────
section "Camera hardware"
if command -v rpicam-hello >/dev/null 2>&1; then
    ok "rpicam-apps installed: $(rpicam-hello --version 2>/dev/null | head -n1)"
    CAM_LIST=$(rpicam-hello --list-cameras 2>&1)
    if echo "$CAM_LIST" | grep -qi 'imx500'; then
        ok "IMX500 sensor detected"
        echo "$CAM_LIST" | grep -i 'imx500' | sed 's/^/      /'
    elif echo "$CAM_LIST" | grep -qi 'Available cameras'; then
        warn "Camera detected but not IMX500:"
        echo "$CAM_LIST" | grep -v '^$' | sed 's/^/      /'
    else
        fail "No camera detected by rpicam-hello"
        echo "$CAM_LIST" | sed 's/^/      /'
    fi
else
    fail "rpicam-hello not installed (camera will not work)"
fi

# Video device nodes
VIDEO_DEVS=$(ls /dev/video* 2>/dev/null | wc -l)
if [[ "$VIDEO_DEVS" -gt 0 ]]; then
    ok "Video devices present: $(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
else
    warn "No /dev/video* devices — camera may not be wired up"
fi

# IMX500 AI post-process asset
POST_PROC="/usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json"
if [[ -f "$POST_PROC" ]]; then
    ok "AI preset present: $POST_PROC"
else
    warn "AI preset missing: $POST_PROC  (AI overlay disabled if enabled in camera-stream.sh)"
fi

# ─── Encoder toolchain ───────────────────────────────────────
section "Encoder toolchain"
if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg installed: $(ffmpeg -version 2>/dev/null | head -n1)"
else
    fail "ffmpeg not installed — deploy.sh installs this; re-run if missing"
fi

# ─── User groups ─────────────────────────────────────────────
section "User permissions"
TARGET_USER="${SUDO_USER:-$USER}"
USER_GROUPS=$(id -nG "$TARGET_USER" 2>/dev/null)
info "Checking groups for user: $TARGET_USER"
for g in video render; do
    if echo " $USER_GROUPS " | grep -q " $g "; then
        ok "User '$TARGET_USER' is in group '$g'"
    else
        warn "User '$TARGET_USER' is NOT in group '$g' — camera access may fail"
    fi
done

# ─── MediaMTX ────────────────────────────────────────────────
section "MediaMTX"
if [[ -x /usr/local/bin/mediamtx ]]; then
    MTX_VER=$(/usr/local/bin/mediamtx --version 2>/dev/null | head -n1)
    ok "Binary installed: /usr/local/bin/mediamtx ${MTX_VER:+($MTX_VER)}"
else
    fail "MediaMTX binary missing at /usr/local/bin/mediamtx"
fi

if [[ -f /etc/mediamtx/mediamtx.yml ]]; then
    ok "Config present: /etc/mediamtx/mediamtx.yml"
else
    fail "Config missing: /etc/mediamtx/mediamtx.yml"
fi

if systemctl list-unit-files mediamtx.service >/dev/null 2>&1 && \
   systemctl cat mediamtx.service >/dev/null 2>&1; then
    ok "Unit installed: mediamtx.service"
    if systemctl is-enabled --quiet mediamtx.service; then
        ok "Enabled on boot"
    else
        warn "NOT enabled on boot (run: sudo cam-ctrl enable)"
    fi
    if systemctl is-active --quiet mediamtx.service; then
        ok "Running (active)"
        info "Since: $(systemctl show mediamtx.service -p ActiveEnterTimestamp --value)"
    else
        fail "NOT running"
        echo -e "    ${DIM}Last 8 log lines:${NC}"
        journalctl -u mediamtx -n 8 --no-pager 2>/dev/null | sed 's/^/      /'
    fi
else
    fail "Unit missing: mediamtx.service (run deploy.sh)"
fi

# ─── camera-stream ───────────────────────────────────────────
section "camera-stream"
if [[ -x /usr/local/bin/camera-stream.sh ]]; then
    ok "Script installed: /usr/local/bin/camera-stream.sh"
else
    fail "Script missing: /usr/local/bin/camera-stream.sh"
fi

if systemctl list-unit-files camera-stream.service >/dev/null 2>&1 && \
   systemctl cat camera-stream.service >/dev/null 2>&1; then
    ok "Unit installed: camera-stream.service"
    if systemctl is-enabled --quiet camera-stream.service; then
        ok "Enabled on boot"
    else
        warn "NOT enabled on boot (run: sudo cam-ctrl enable)"
    fi
    if systemctl is-active --quiet camera-stream.service; then
        ok "Running (active)"
        info "Since: $(systemctl show camera-stream.service -p ActiveEnterTimestamp --value)"

        # Confirm libx264 zerolatency tune is engaged — see CLAUDE.md
        if journalctl -u camera-stream -n 200 --no-pager 2>/dev/null | grep -q 'Constrained Baseline'; then
            ok "libx264 zerolatency tune engaged (log shows 'Constrained Baseline')"
        elif journalctl -u camera-stream -n 200 --no-pager 2>/dev/null | grep -q 'Error setting preset/tune'; then
            fail "libx264 rejected preset/tune options — check the ';' separator in --libav-video-codec-opts"
        else
            warn "Could not confirm zerolatency tune from recent logs — stream may still be initializing"
        fi
    else
        fail "NOT running"
        echo -e "    ${DIM}Last 12 log lines:${NC}"
        journalctl -u camera-stream -n 12 --no-pager 2>/dev/null | sed 's/^/      /'
    fi
else
    fail "Unit missing: camera-stream.service (run deploy.sh)"
fi

# ─── cam-ctrl ────────────────────────────────────────────────
section "cam-ctrl tool"
if [[ -x /usr/local/bin/cam-ctrl ]]; then
    ok "Installed: /usr/local/bin/cam-ctrl"
else
    fail "Missing: /usr/local/bin/cam-ctrl (run deploy.sh)"
fi

# ─── Ports ───────────────────────────────────────────────────
section "Network listeners"
check_port() {
    local port="$1"; local label="$2"
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"; then
            ok "Port $port ($label) is listening"
        else
            fail "Port $port ($label) is NOT listening"
        fi
    else
        warn "ss not available — cannot check port $port"
    fi
}
check_port 8554 "RTSP"
check_port 8888 "HLS"
check_port 8889 "WebRTC"
check_port 9997 "MediaMTX API"

# ─── MediaMTX API ────────────────────────────────────────────
section "MediaMTX REST API"
if curl -sf --max-time 3 "http://localhost:9997/v3/paths/list" >/dev/null 2>&1; then
    ok "API reachable at http://localhost:9997"
    if command -v python3 >/dev/null 2>&1; then
        PATHS_INFO=$(curl -sf "http://localhost:9997/v3/paths/list" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('items', [])
    for i in items:
        name = i.get('name','?')
        ready = i.get('ready', False)
        readers = len(i.get('readers', []))
        src = i.get('source', {}) or {}
        src_type = src.get('type', 'none') if isinstance(src, dict) else 'none'
        flag = 'READY' if ready else 'NOT READY'
        print(f'    [{flag}] path={name}  source={src_type}  readers={readers}')
    if not items:
        print('    (no paths registered)')
except Exception as e:
    print(f'    (parse error: {e})')
")
        echo "$PATHS_INFO"
    fi
else
    fail "API NOT reachable — MediaMTX is likely down"
fi

# ─── Tailscale ───────────────────────────────────────────────
section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
    ok "Installed: $(tailscale version 2>/dev/null | head -n1)"
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
        ok "tailscaled running"
    else
        fail "tailscaled NOT running (sudo systemctl start tailscaled)"
    fi
    TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
    if [[ -n "$TS_IP" ]]; then
        ok "Connected — Tailscale IPv4: $TS_IP"
        # Show backend state for clarity
        TS_STATE=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | head -n1 | cut -d'"' -f4)
        [[ -n "$TS_STATE" ]] && info "Backend state: $TS_STATE"
    else
        fail "Tailscale installed but no IPv4 — run: sudo tailscale up"
    fi
else
    fail "Tailscale not installed — run: sudo bash tailscale-setup.sh"
fi

# ─── Local stream reachability ───────────────────────────────
section "Local stream reachability"
if command -v ffprobe >/dev/null 2>&1; then
    info "Probing rtsp://127.0.0.1:8554/cam (5s timeout)..."
    if ffprobe -v error -rtsp_transport tcp -timeout 5000000 \
        -i rtsp://127.0.0.1:8554/cam 2>/dev/null >/dev/null; then
        ok "Stream is publishing and readable on local RTSP"
    else
        fail "ffprobe could not read the local RTSP stream"
    fi
else
    warn "ffprobe not available — skipping live stream probe"
fi

# ─── Summary ─────────────────────────────────────────────────
section "Summary"
if [[ "$FAILS" -eq 0 && "$WARNS" -eq 0 ]]; then
    echo -e "  ${GREEN}All checks passed.${NC}"
elif [[ "$FAILS" -eq 0 ]]; then
    echo -e "  ${GREEN}No failures.${NC} ${YELLOW}$WARNS warning(s).${NC}"
else
    echo -e "  ${RED}$FAILS failure(s)${NC}, ${YELLOW}$WARNS warning(s).${NC}"
    echo
    info "Common next steps:"
    echo "    sudo cam-ctrl restart-all   # bounce everything"
    echo "    cam-ctrl logs               # inspect recent errors"
    echo "    sudo bash deploy.sh         # re-apply install"
fi
hr
echo

# Exit non-zero on any failure so this script is usable in CI / scripts
[[ "$FAILS" -gt 0 ]] && exit 1 || exit 0
