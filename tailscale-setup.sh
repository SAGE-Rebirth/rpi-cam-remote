#!/bin/bash
# =============================================================
#  Tailscale One-Command Setup for Raspberry Pi
#  Installs Tailscale and joins this Pi to your tailnet.
#  Run on the Pi: sudo bash tailscale-setup.sh
#
#  Optional:
#    TS_AUTHKEY=tskey-auth-xxxx sudo -E bash tailscale-setup.sh
#    TS_HOSTNAME=rpi-cam        sudo -E bash tailscale-setup.sh
#  Without TS_AUTHKEY, you'll be given a login URL to open.
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
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo bash tailscale-setup.sh"

# ─── Config ──────────────────────────────────────────────────
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

hr
echo -e "${CYAN}  Tailscale Setup for $(hostname)${NC}"
hr

# ─── Step 1: Install Tailscale ───────────────────────────────
if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale already installed: $(tailscale version | head -n1)"
else
    log "Installing Tailscale via official install script..."
    if ! command -v curl >/dev/null 2>&1; then
        log "Installing curl (required for installer)..."
        apt-get update -qq
        apt-get install -y curl
    fi
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# ─── Step 2: Ensure tailscaled is running ────────────────────
log "Enabling and starting tailscaled..."
systemctl enable --now tailscaled

# ─── Step 3: Bring the node up ───────────────────────────────
if tailscale status >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
    warn "Tailscale is already logged in as: $(tailscale status --json | grep -o '\"DNSName\":\"[^\"]*\"' | head -n1 | cut -d'\"' -f4)"
    info "Skipping 'tailscale up'. To re-auth, run: sudo tailscale logout && sudo bash tailscale-setup.sh"
else
    UP_ARGS=(--ssh --hostname="$TS_HOSTNAME" --accept-routes)
    if [[ -n "$TS_AUTHKEY" ]]; then
        log "Bringing Tailscale up with provided auth key..."
        UP_ARGS+=(--authkey="$TS_AUTHKEY")
        tailscale up "${UP_ARGS[@]}"
    else
        log "Bringing Tailscale up. Open the URL below in a browser to authenticate:"
        echo
        tailscale up "${UP_ARGS[@]}"
    fi
fi

# ─── Step 4: Report result ───────────────────────────────────
hr
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ -z "$TS_IP" ]]; then
    err "Tailscale did not come up — check 'sudo tailscale status' and 'journalctl -u tailscaled'."
fi
log "Tailscale is up."
info "Hostname:     $TS_HOSTNAME"
info "Tailnet IPv4: $TS_IP"
info "SSH access:   ssh ${SUDO_USER:-$USER}@${TS_IP}"
hr
log "Next step: sudo bash deploy.sh"
