#!/bin/bash
# =============================================================
#  Wi-Fi priority + powersave-off setup
#  Forces the Pi to prefer a specific SSID on every boot/reconnect
#  and disables Wi-Fi power management so reconnects are immediate.
#
#  Run on the Pi: sudo bash wifi-priority.sh ["SSID"]
#
#  Examples:
#    sudo bash wifi-priority.sh                  # defaults to "OnePlus 12"
#    sudo bash wifi-priority.sh "MyHotspot"
#    sudo bash wifi-priority.sh "OnePlus 12" --no-reboot
#    sudo bash wifi-priority.sh "OnePlus 12" --yes
#
#  What this does:
#    1. Writes /etc/NetworkManager/conf.d/wifi-powersave-off.conf
#       (wifi.powersave = 2 → disabled, applied globally on NM reload)
#    2. Sets powersave off on the live wlan0 interface
#    3. For every NM profile whose SSID matches the target:
#         connection.autoconnect       yes
#         connection.autoconnect-priority 10
#         connection.autoconnect-retries  0   (forever)
#         802-11-wireless.powersave       2   (disabled)
#    4. Reloads NetworkManager
#    5. Prints verification of all the above
#    6. Reboots (unless --no-reboot, and after a confirm unless --yes)
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
[[ $EUID -ne 0 ]] && err "Run with sudo: sudo bash wifi-priority.sh [\"SSID\"]"

# ─── Args ────────────────────────────────────────────────────
TARGET_SSID="OnePlus 12"
DO_REBOOT=1
SKIP_CONFIRM=0
IFACE="wlan0"

positional_seen=0
for arg in "$@"; do
    case "$arg" in
        --no-reboot) DO_REBOOT=0 ;;
        --yes|-y)    SKIP_CONFIRM=1 ;;
        --iface=*)   IFACE="${arg#--iface=}" ;;
        --help|-h)
            sed -n '2,30p' "$0"; exit 0 ;;
        --*) err "Unknown flag: $arg" ;;
        *)
            if [[ $positional_seen -eq 0 ]]; then
                TARGET_SSID="$arg"
                positional_seen=1
            else
                err "Unexpected extra argument: $arg"
            fi
            ;;
    esac
done

PRIORITY=10
RETRIES=0
POWERSAVE_DISABLED=2   # NM enum: 0=default 1=ignore 2=disable 3=enable
NM_CONF_FILE="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"

hr
echo -e "${CYAN}  Wi-Fi priority + powersave-off setup${NC}"
hr
info "Target SSID    : \"$TARGET_SSID\""
info "Interface      : $IFACE"
info "Priority       : $PRIORITY"
info "Retries        : $RETRIES (forever)"
info "Reboot at end  : $([[ $DO_REBOOT -eq 1 ]] && echo yes || echo no)"
hr

# ─── Sanity: NetworkManager + nmcli present ──────────────────
if ! command -v nmcli >/dev/null 2>&1; then
    err "nmcli not found — this script needs NetworkManager (Pi OS Bookworm and newer)."
fi
if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    warn "NetworkManager service is not active — attempting to start it..."
    systemctl start NetworkManager || err "Could not start NetworkManager."
fi

# ─── Step 1: Permanent powersave-off via conf.d ──────────────
log "Writing $NM_CONF_FILE (permanent powersave-off)..."
mkdir -p "$(dirname "$NM_CONF_FILE")"
cat > "$NM_CONF_FILE" <<'EOF'
# Managed by rpi-cam/wifi-priority.sh — do not edit by hand.
# Disable Wi-Fi power saving globally so reconnects are immediate
# and the link doesn't drop in/out under low traffic.
# NM enum: 0=default 1=ignore 2=disable 3=enable
[connection]
wifi.powersave = 2
EOF
chmod 644 "$NM_CONF_FILE"
info "Wrote $NM_CONF_FILE"

# ─── Step 2: Disable powersave on the live interface ─────────
log "Disabling Wi-Fi power management on $IFACE (live)..."
if command -v iw >/dev/null 2>&1; then
    iw dev "$IFACE" set power_save off 2>/dev/null && \
        info "iw: power_save off on $IFACE" || \
        warn "iw failed to disable powersave on $IFACE (may already be off)"
elif command -v iwconfig >/dev/null 2>&1; then
    iwconfig "$IFACE" power off 2>/dev/null && \
        info "iwconfig: power off on $IFACE" || \
        warn "iwconfig failed to disable powersave on $IFACE"
else
    warn "Neither 'iw' nor 'iwconfig' found — live powersave-off skipped (the conf.d file will apply on reload/reboot)"
fi

# ─── Step 3: Find all NM profiles for the target SSID ────────
log "Looking for NetworkManager profiles with SSID \"$TARGET_SSID\"..."

# Iterate all wifi profiles and read each one's configured SSID.
# We match by SSID — not profile name — so we catch both
# "OnePlus 12" and "netplan-wlan0-OnePlus 12" automatically.
mapfile -t WIFI_PROFILES < <(nmcli -t -f NAME,TYPE connection show \
    | awk -F: '$2 == "802-11-wireless" {print $1}')

if [[ ${#WIFI_PROFILES[@]} -eq 0 ]]; then
    warn "No Wi-Fi profiles found in NetworkManager."
    warn "Connect to \"$TARGET_SSID\" once manually (nmcli device wifi connect ...) and re-run."
    MATCHED=()
else
    MATCHED=()
    for prof in "${WIFI_PROFILES[@]}"; do
        # -g returns just the field value, unescaped
        ssid=$(nmcli -g 802-11-wireless.ssid connection show "$prof" 2>/dev/null)
        if [[ "$ssid" == "$TARGET_SSID" ]]; then
            MATCHED+=("$prof")
        fi
    done
fi

if [[ ${#MATCHED[@]} -eq 0 ]]; then
    warn "No saved profile matches SSID \"$TARGET_SSID\"."
    warn "To create one now (you'll be asked for the Wi-Fi password):"
    echo  "    sudo nmcli device wifi connect \"$TARGET_SSID\" --ask"
    warn "After connecting once, re-run this script to set priority/retries/powersave."
else
    info "Matched ${#MATCHED[@]} profile(s):"
    for p in "${MATCHED[@]}"; do echo "      • $p"; done

    log "Applying autoconnect + powersave settings..."
    for prof in "${MATCHED[@]}"; do
        nmcli connection modify "$prof" \
            connection.autoconnect           yes \
            connection.autoconnect-priority  "$PRIORITY" \
            connection.autoconnect-retries   "$RETRIES" \
            802-11-wireless.powersave        "$POWERSAVE_DISABLED" \
            && info "Updated: $prof" \
            || warn "Failed to update: $prof"
    done
fi

# ─── Step 4: Reload NetworkManager to pick up conf.d ─────────
log "Reloading NetworkManager configuration..."
nmcli general reload >/dev/null 2>&1 && info "nmcli general reload OK" || \
    warn "nmcli general reload failed — a reboot will apply settings regardless"

# ─── Step 5: Verification ────────────────────────────────────
hr
echo -e "${CYAN}  Verification${NC}"
hr

echo
echo -e "${CYAN}  Live powersave status ($IFACE):${NC}"
if command -v iwconfig >/dev/null 2>&1; then
    iwconfig "$IFACE" 2>/dev/null | grep -i "Power Management" | sed 's/^/    /' \
        || echo "    (iwconfig output unavailable)"
elif command -v iw >/dev/null 2>&1; then
    iw dev "$IFACE" get power_save 2>/dev/null | sed 's/^/    /' \
        || echo "    (iw output unavailable)"
fi

if [[ ${#MATCHED[@]} -gt 0 ]]; then
    for prof in "${MATCHED[@]}"; do
        echo
        echo -e "${CYAN}  Profile: $prof${NC}"
        nmcli connection show "$prof" 2>/dev/null \
            | grep -iE 'connection.autoconnect|802-11-wireless.powersave' \
            | sed 's/^/    /'
    done
fi

echo
echo -e "${CYAN}  Global powersave conf:${NC}"
echo "    $NM_CONF_FILE"
grep -E 'wifi\.powersave' "$NM_CONF_FILE" | sed 's/^/      /'

hr

# ─── Step 6: Reboot ──────────────────────────────────────────
if [[ $DO_REBOOT -eq 1 ]]; then
    if [[ $SKIP_CONFIRM -eq 0 ]]; then
        echo
        warn "A reboot is recommended so every component picks up the new config."
        warn "If you are SSH'd in over Wi-Fi, your session will drop — that's expected."
        read -r -p "Reboot now? [Y/n] " reply
        reply="${reply:-Y}"
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            info "Skipping reboot. Run 'sudo reboot' yourself when ready."
            exit 0
        fi
    fi
    log "Rebooting in 3 seconds... (Ctrl+C to cancel)"
    sleep 3
    systemctl reboot
else
    info "Reboot skipped (--no-reboot). Run 'sudo reboot' yourself to fully apply."
fi
