#!/bin/bash
# =============================================================
#  rpi-cam uninstaller — removes everything deploy.sh installed
#  Run on the Pi: sudo bash uninstall.sh
#
#  Removes:
#    - camera-stream + mediamtx systemd services
#    - /usr/local/bin/{mediamtx, camera-stream.sh, cam-ctrl}
#    - /etc/mediamtx/
#  Optional (asks per-component):
#    - Tailscale  (in case you use it for other purposes)
#    - ffmpeg     (in case other tools depend on it)
#
#  Does NOT touch:
#    - This rpi-cam folder (the user's working copy)
#    - The user's home directory
#    - System packages other than the ones above
#
#  Flags:
#    --yes        skip the initial confirmation
#    --tailscale  also remove Tailscale (no prompt)
#    --ffmpeg     also remove ffmpeg (no prompt)
#    --keep-tailscale, --keep-ffmpeg  inverse, for fully scripted runs
# =============================================================

set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
hr()   { echo -e "${BLUE}────────────────────────────────────────────────${NC}"; }

# ─── Must run as root ────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo bash uninstall.sh"

# ─── Parse flags ─────────────────────────────────────────────
SKIP_CONFIRM=0
REMOVE_TAILSCALE=""   # "", "yes", "no"
REMOVE_FFMPEG=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y)         SKIP_CONFIRM=1 ;;
        --tailscale)      REMOVE_TAILSCALE="yes" ;;
        --keep-tailscale) REMOVE_TAILSCALE="no" ;;
        --ffmpeg)         REMOVE_FFMPEG="yes" ;;
        --keep-ffmpeg)    REMOVE_FFMPEG="no" ;;
        *) err "Unknown flag: $arg" ;;
    esac
done

# ─── Helper: yes/no prompt with default ──────────────────────
confirm() {
    local prompt="$1"; local default="${2:-N}"; local reply
    if [[ "$SKIP_CONFIRM" -eq 1 ]]; then
        [[ "$default" == "Y" ]] && return 0 || return 1
    fi
    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n] " reply
        reply="${reply:-Y}"
    else
        read -r -p "$prompt [y/N] " reply
        reply="${reply:-N}"
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

hr
echo -e "${CYAN}  rpi-cam uninstaller${NC}"
hr
echo
echo "This will remove the following from your Pi:"
echo "    • systemd services: mediamtx, camera-stream"
echo "    • /usr/local/bin/mediamtx"
echo "    • /usr/local/bin/camera-stream.sh"
echo "    • /usr/local/bin/cam-ctrl"
echo "    • /etc/mediamtx/"
echo
echo "It will NOT touch this rpi-cam folder or your home directory."
echo "You will be asked separately whether to remove Tailscale and ffmpeg."
echo

if [[ "$SKIP_CONFIRM" -ne 1 ]]; then
    if ! confirm "Continue?" "N"; then
        info "Aborted by user."
        exit 0
    fi
fi

# ─── Stop and disable services ───────────────────────────────
hr
log "Stopping and disabling services..."
for svc in camera-stream mediamtx; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && \
       systemctl cat "${svc}.service" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc"; then
            info "Stopping ${svc}..."
            systemctl stop "$svc" || warn "Failed to stop $svc cleanly"
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            info "Disabling ${svc}..."
            systemctl disable "$svc" 2>/dev/null || true
        fi
    else
        info "${svc}.service not installed — skipping"
    fi
done

# ─── Remove unit files ───────────────────────────────────────
log "Removing systemd unit files..."
for unit in /etc/systemd/system/camera-stream.service /etc/systemd/system/mediamtx.service; do
    if [[ -f "$unit" ]]; then
        rm -f "$unit" && info "Removed $unit"
    fi
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

# ─── Make sure no stray rpicam-vid / ffmpeg pipeline lingers ─
log "Killing any stray pipeline processes..."
pkill -f 'rpicam-vid' 2>/dev/null && info "Killed lingering rpicam-vid" || true
pkill -f 'ffmpeg.*rtsp://127.0.0.1:8554' 2>/dev/null && info "Killed lingering ffmpeg push" || true

# ─── Remove installed binaries and scripts ───────────────────
log "Removing installed binaries and scripts..."
for f in /usr/local/bin/mediamtx /usr/local/bin/camera-stream.sh /usr/local/bin/cam-ctrl; do
    if [[ -e "$f" ]]; then
        rm -f "$f" && info "Removed $f"
    fi
done

# ─── Remove config dir ───────────────────────────────────────
if [[ -d /etc/mediamtx ]]; then
    log "Removing /etc/mediamtx/ ..."
    rm -rf /etc/mediamtx
    info "Removed /etc/mediamtx/"
fi

# ─── Optional: Tailscale ─────────────────────────────────────
hr
if command -v tailscale >/dev/null 2>&1; then
    if [[ -z "$REMOVE_TAILSCALE" ]]; then
        echo
        warn "Tailscale is installed. Removing it will sign this Pi out of your tailnet"
        warn "and may break other Tailscale-dependent setups."
        if confirm "Remove Tailscale?" "N"; then
            REMOVE_TAILSCALE="yes"
        else
            REMOVE_TAILSCALE="no"
        fi
    fi

    if [[ "$REMOVE_TAILSCALE" == "yes" ]]; then
        log "Logging out and removing Tailscale..."
        tailscale logout 2>/dev/null || true
        systemctl stop tailscaled 2>/dev/null || true
        systemctl disable tailscaled 2>/dev/null || true
        if dpkg -s tailscale >/dev/null 2>&1; then
            apt-get remove --purge -y tailscale tailscale-archive-keyring 2>/dev/null || \
                apt-get remove --purge -y tailscale
            apt-get autoremove -y
        fi
        rm -rf /var/lib/tailscale /etc/default/tailscaled \
               /etc/apt/sources.list.d/tailscale.list \
               /usr/share/keyrings/tailscale-archive-keyring.gpg
        info "Tailscale removed"
    else
        info "Keeping Tailscale installed"
    fi
else
    info "Tailscale not installed — nothing to remove"
fi

# ─── Optional: ffmpeg ────────────────────────────────────────
hr
if dpkg -s ffmpeg >/dev/null 2>&1; then
    if [[ -z "$REMOVE_FFMPEG" ]]; then
        echo
        warn "ffmpeg is a general-purpose tool that other programs may depend on."
        if confirm "Remove ffmpeg?" "N"; then
            REMOVE_FFMPEG="yes"
        else
            REMOVE_FFMPEG="no"
        fi
    fi

    if [[ "$REMOVE_FFMPEG" == "yes" ]]; then
        log "Removing ffmpeg..."
        apt-get remove --purge -y ffmpeg
        apt-get autoremove -y
        info "ffmpeg removed"
    else
        info "Keeping ffmpeg installed"
    fi
else
    info "ffmpeg not installed via apt — nothing to remove"
fi

# ─── Done ────────────────────────────────────────────────────
hr
log "Uninstall complete."
echo
info "The rpi-cam folder at $(dirname "$(readlink -f "$0")") was left intact."
info "To reinstall later: sudo bash deploy.sh"
hr
