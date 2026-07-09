#!/usr/bin/env bash
# install.sh — install airlock on an existing Raspberry Pi.
#
# Usage:
#   curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash
#   or
#   sudo ./install.sh
#
# Environment overrides:
#   AIRLOCK_VERSION       git tag to install (default: latest release)
#   AIRLOCK_REPO          GitHub repo (default: emdzej/airlock)
#   AIRLOCK_BINARY_URL    override the binary tarball URL entirely
#   AIRLOCK_LOCAL_BINARY  path to a locally-built binary (skips download)
#   AIRLOCK_PREFIX        install prefix (default: /usr/local)
#   AIRLOCK_HARDEN_USB    set to 1 to block HID / CDC-* USB drivers (opt-in)
#   AIRLOCK_FAST_BOOT     set to 1 to disable services + BT firmware not
#                         needed on a headless appliance (~7-10s off boot)
#   AIRLOCK_DISABLE_WIFI  set to 1 to disable the Wi-Fi radio via config.txt
#                         (only if this Pi uses Ethernet — otherwise it
#                         will become unreachable after reboot)
#
# The script is idempotent — safe to re-run to upgrade or repair an install.

set -euo pipefail

REPO="${AIRLOCK_REPO:-emdzej/airlock}"
VERSION="${AIRLOCK_VERSION:-}"
PREFIX="${AIRLOCK_PREFIX:-/usr/local}"
LOCAL_BINARY="${AIRLOCK_LOCAL_BINARY:-}"
HARDEN_USB="${AIRLOCK_HARDEN_USB:-0}"
FAST_BOOT="${AIRLOCK_FAST_BOOT:-0}"
DISABLE_WIFI="${AIRLOCK_DISABLE_WIFI:-0}"

# --- output helpers ---
if [[ -t 2 ]]; then
    _bold=$'\033[1m'; _blue=$'\033[1;34m'; _yellow=$'\033[1;33m'; _red=$'\033[1;31m'; _reset=$'\033[0m'
else
    _bold=""; _blue=""; _yellow=""; _red=""; _reset=""
fi
log()  { printf "%s==>%s %s\n" "$_blue" "$_reset" "$*" >&2; }
warn() { printf "%s==>%s %s\n" "$_yellow" "$_reset" "$*" >&2; }
err()  { printf "%s==>%s %s\n" "$_red" "$_reset" "$*" >&2; exit 1; }

# --- preflight ---
[[ $EUID -eq 0 ]] || err "must run as root — retry with sudo"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091  # /etc/os-release provided by the OS at runtime
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*) ;;
        *) warn "not a Debian-based system (ID=$ID) — proceeding, but nothing is guaranteed" ;;
    esac
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
    arm64|aarch64) ARCH=arm64 ;;
    *) err "only arm64 / aarch64 is supported; got $ARCH" ;;
esac

# The Samba share owner must exist as a Unix user whose UID matches the mount
# options the daemon uses (1000). On a fresh Raspberry Pi OS install this is
# whatever first-user was set via Pi Imager.
SHARE_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
[[ -n "$SHARE_USER" ]] || err "no user found with UID 1000. Create one first, or set AIRLOCK_OWNER_UID."
log "share owner: ${_bold}$SHARE_USER${_reset} (uid 1000)"

# --- resolve version ---
if [[ -z "$VERSION" && -z "$LOCAL_BINARY" ]]; then
    log "fetching latest release tag from github.com/$REPO"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')" || true
    [[ -n "$VERSION" ]] || err "could not determine latest version; set AIRLOCK_VERSION manually"
fi
if [[ -n "$LOCAL_BINARY" ]]; then
    log "using local binary: $LOCAL_BINARY"
else
    log "installing version: ${_bold}$VERSION${_reset}"
fi

# --- install apt packages ---
log "installing prerequisite packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    samba samba-common-bin \
    avahi-daemon libnss-mdns \
    exfatprogs ntfs-3g dosfstools e2fsprogs hfsprogs \
    gdisk parted util-linux \
    ca-certificates curl

# --- get the binary ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$LOCAL_BINARY" ]]; then
    [[ -x "$LOCAL_BINARY" ]] || err "$LOCAL_BINARY is not executable"
    cp "$LOCAL_BINARY" "$TMP/airlockd"
else
    URL="${AIRLOCK_BINARY_URL:-https://github.com/$REPO/releases/download/$VERSION/airlockd-${VERSION}-linux-arm64.tar.gz}"
    log "downloading $URL"
    curl -fsSL "$URL" -o "$TMP/airlockd.tar.gz"
    tar -xzf "$TMP/airlockd.tar.gz" -C "$TMP" airlockd
fi
[[ -x "$TMP/airlockd" ]] || err "airlockd binary is missing or not executable"

# --- install binary ---
log "installing binary to $PREFIX/bin/airlockd"
install -D -m 0755 "$TMP/airlockd" "$PREFIX/bin/airlockd"

# --- systemd unit ---
log "installing systemd unit (with sandbox)"
cat > /etc/systemd/system/airlockd.service <<'UNIT'
[Unit]
Description=Airlock daemon
Documentation=https://github.com/emdzej/airlock
After=network-online.target smbd.service avahi-daemon.service
Wants=network-online.target smbd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/airlockd
Restart=on-failure
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

# systemd sandbox (seccomp + prctl only — no mount ns).
NoNewPrivileges=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
UNIT

# --- udev rule ---
log "installing udev rule"
cat > /etc/udev/rules.d/99-airlock.rules <<'UDEV'
# airlock — match only USB-attached block devices. Native SD (mmcblk*) is
# explicitly excluded so we never expose /boot/firmware or / over SMB.
SUBSYSTEM=="block", KERNEL=="sd[a-z]*", ENV{ID_BUS}=="usb", ENV{AIRLOCK_MANAGED}="1"
UDEV

# --- Samba base config ---
if [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.airlock-backup ]]; then
    log "backing up existing /etc/samba/smb.conf → /etc/samba/smb.conf.airlock-backup"
    cp -a /etc/samba/smb.conf /etc/samba/smb.conf.airlock-backup
fi

log "installing samba base config"
cat > /etc/samba/smb.conf <<'SMB'
[global]
    workgroup = WORKGROUP
    server string = Airlock
    server role = standalone server
    netbios name = airlock
    map to guest = Bad User
    guest account = nobody
    security = user
    server min protocol = SMB2
    client min protocol = SMB2
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
    log level = 1
    max log size = 1000
    log file = /var/log/samba/log.%m
    include = /etc/samba/smb.conf.d/airlock.conf
SMB

mkdir -p /etc/samba/smb.conf.d
touch /etc/samba/smb.conf.d/airlock.conf
chmod 0644 /etc/samba/smb.conf.d/airlock.conf

# --- Avahi service ---
log "installing avahi service advertisement"
mkdir -p /etc/avahi/services
cat > /etc/avahi/services/airlock.service <<'AVAHI'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Airlock on %h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
  </service>
  <!-- Tells macOS Finder to render this as a disk / Time Capsule -->
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=TimeCapsule6,106</txt-record>
  </service>
</service-group>
AVAHI

# --- Mount base dir ---
mkdir -p /mnt/airlock

# --- Optional: fast-boot service disables ---
if [[ "$FAST_BOOT" == "1" ]]; then
    log "applying fast-boot optimizations (AIRLOCK_FAST_BOOT=1)"
    # Services not needed on a headless airlock appliance. Failures are
    # ignored — some names differ across Trixie / Bookworm / Raspbian
    # versions or aren't installed at all.
    for svc in bluetooth.service hciuart.service \
               triggerhappy.service triggerhappy.socket \
               ModemManager.service \
               nmbd.service samba-ad-dc.service winbind.service \
               apt-daily.timer apt-daily-upgrade.timer \
               e2scrub_reap.service e2scrub_all.timer \
               dphys-swapfile.service \
               NetworkManager-wait-online.service \
               rpi-eeprom-update.service; do
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
    done
    for svc in keyboard-setup.service console-setup.service; do
        systemctl mask "$svc" >/dev/null 2>&1 || true
    done
    # Cloud-init has done its first-boot job by the time you're running
    # this installer. Turn it off so it stops adding ~2 s to every boot.
    if [ -d /etc/cloud ]; then
        touch /etc/cloud/cloud-init.disabled
        for svc in cloud-init-main.service cloud-init-local.service \
                   cloud-init-network.service cloud-config.service \
                   cloud-final.service; do
            systemctl disable "$svc" >/dev/null 2>&1 || true
        done
    fi
    # Firmware-level: skip Bluetooth radio init (~1 s saved in kernel time).
    if [ -f /boot/firmware/config.txt ] && ! grep -q "^dtoverlay=disable-bt" /boot/firmware/config.txt; then
        echo "dtoverlay=disable-bt" >> /boot/firmware/config.txt
        log "added dtoverlay=disable-bt to /boot/firmware/config.txt"
    fi
    warn "fast-boot done — reboot to apply firmware changes"
fi

# --- Optional: disable Wi-Fi radio (Ethernet-only appliance) ---
if [[ "$DISABLE_WIFI" == "1" ]]; then
    log "disabling Wi-Fi radio (AIRLOCK_DISABLE_WIFI=1)"
    if [ ! -f /boot/firmware/config.txt ]; then
        warn "/boot/firmware/config.txt not found; skipping Wi-Fi disable"
    else
        # Only proceed if this Pi actually has an Ethernet link — otherwise
        # disabling Wi-Fi orphans the box.
        if ip -brief link show eth0 2>/dev/null | grep -q "UP"; then
            if ! grep -q "^dtoverlay=disable-wifi" /boot/firmware/config.txt; then
                echo "dtoverlay=disable-wifi" >> /boot/firmware/config.txt
                log "added dtoverlay=disable-wifi (takes effect on next reboot)"
            else
                log "dtoverlay=disable-wifi already present"
            fi
        else
            err "eth0 is not up — refusing to disable Wi-Fi (would orphan this Pi)"
        fi
    fi
fi

# --- Optional USB class blocklist ---
# When AIRLOCK_HARDEN_USB=1, install the modprobe file that refuses HID
# (keyboards/mice) and CDC-* (USB Ethernet, serial) drivers. USB mass
# storage is unaffected. Skip if you still want to plug a keyboard in.
if [[ "$HARDEN_USB" == "1" ]]; then
    log "installing USB class blocklist (opt-in, AIRLOCK_HARDEN_USB=1)"
    SRC_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    if [[ -f "$SRC_DIR/modprobe-airlock.conf" ]]; then
        install -D -m 0644 "$SRC_DIR/modprobe-airlock.conf" \
            /etc/modprobe.d/modprobe-airlock.conf
    else
        # Curl-piped install: no local script dir — download from repo.
        curl -fsSL "https://raw.githubusercontent.com/$REPO/main/scripts/modprobe-airlock.conf" \
            -o /etc/modprobe.d/modprobe-airlock.conf
        chmod 0644 /etc/modprobe.d/modprobe-airlock.conf
    fi
    systemctl restart systemd-udevd || true
    warn "USB HID + CDC drivers now blocked. Reboot to apply fully."
else
    log "USB class blocklist skipped (set AIRLOCK_HARDEN_USB=1 to enable)"
fi

# --- reload + start ---
log "reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload

log "enabling and starting services"
systemctl enable smbd airlockd avahi-daemon >/dev/null 2>&1 || true
systemctl restart smbd
systemctl reload avahi-daemon 2>/dev/null || systemctl restart avahi-daemon
systemctl restart airlockd

sleep 2
if systemctl is-active --quiet airlockd; then
    HOST="$(hostname)"
    IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo
    echo "${_bold}Airlock is running.${_reset}"
    echo "  Web UI:  http://${HOST}.local/  (or http://${IP}/)"
    echo "  SMB:     smb://${HOST}.local/   (guest access, no password)"
    echo
    echo "Plug in a USB drive to see it appear on the network."
    echo "Logs:  journalctl -u airlockd -f"
else
    err "airlockd failed to start. Check: journalctl -u airlockd -n 40"
fi
