#!/usr/bin/env bash
# install.sh — install airlock on an existing Raspberry Pi.
#
# Usage:
#   curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash
#   curl -fsSL …/install.sh | sudo AIRLOCK_FAST_BOOT=1 bash    # with options
#   or, from an extracted airlock-<version>-bundle.tar.gz (offline):
#   sudo ./install.sh
#
# Every config file (systemd unit, udev rule, Samba, Avahi, modprobe
# blocklist) comes from the release bundle — the same files the pi-gen
# image is built from (image/pi-gen/stage-airlock/**/files). When run
# from an extracted bundle the local copies are used; when piped from
# curl the bundle is downloaded and checked against its published
# .sha256. Run from a repo checkout (scripts/install.sh), the files are
# taken straight from image/pi-gen/stage-airlock.
#
# Environment overrides:
#   AIRLOCK_VERSION       release tag to install (default: latest release)
#   AIRLOCK_REPO          GitHub repo (default: emdzej/airlock)
#   AIRLOCK_BINARY_URL    override the binary tarball URL entirely
#                         (checked against <url>.sha256 if one exists)
#   AIRLOCK_LOCAL_BINARY  path to a locally-built binary (skips download)
#   AIRLOCK_PREFIX        install prefix (default: /usr/local)
#   AIRLOCK_HARDEN_USB    set to 1 to block HID / CDC-* USB drivers (opt-in)
#   AIRLOCK_FAST_BOOT     set to 1 to disable services + BT firmware not
#                         needed on a headless appliance (~7-10s off boot)
#   AIRLOCK_DISABLE_WIFI  set to 1 to disable the Wi-Fi radio via config.txt
#                         (only if this Pi uses Ethernet — otherwise it
#                         will become unreachable after reboot)
#
# Note: `sudo` drops the caller's environment, so pass variables after
# it — `… | sudo AIRLOCK_X=1 bash`, not `AIRLOCK_X=1 … | sudo bash`.
#
# The script is idempotent — safe to re-run to upgrade or repair an install.

set -euo pipefail

REPO="${AIRLOCK_REPO:-emdzej/airlock}"
VERSION="${AIRLOCK_VERSION:-}"
PREFIX="${AIRLOCK_PREFIX:-/usr/local}"
BINARY_URL="${AIRLOCK_BINARY_URL:-}"
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
        *) warn "not a Debian-based system (ID=${ID:-unknown}) — proceeding, but nothing is guaranteed" ;;
    esac
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
    arm64|aarch64) ARCH=arm64 ;;
    *) err "only arm64 / aarch64 is supported; got $ARCH" ;;
esac

# The Samba share owner must exist as a Unix user with UID 1000 — the
# daemon's mount options and `force user` use that fixed UID. On a fresh
# Raspberry Pi OS install this is the first user set via Pi Imager.
SHARE_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
[[ -n "$SHARE_USER" ]] || err "no user found with UID 1000. Create one first (e.g. sudo adduser --uid 1000 airlock)."
log "share owner: ${_bold}$SHARE_USER${_reset} (uid 1000)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- helpers ---
resolve_version() {
    [[ -n "$VERSION" ]] && return 0
    log "fetching latest release tag from github.com/$REPO"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')" || true
    [[ -n "$VERSION" ]] || err "could not determine latest version; set AIRLOCK_VERSION manually"
}

# fetch_verified URL DEST [optional]
# Downloads URL to DEST and checks it against the hash in URL.sha256.
# With "optional", a missing .sha256 is a warning instead of an error.
fetch_verified() {
    local url="$1" dest="$2" optional="${3:-}" expected actual
    log "downloading $url"
    curl -fsSL "$url" -o "$dest" || err "download failed: $url"
    if ! curl -fsSL "$url.sha256" -o "$dest.sha256"; then
        [[ "$optional" == "optional" ]] || err "no checksum published at $url.sha256 — refusing to install unverified download (releases before 0.4.0 don't publish one for the bundle; install those with their own install.sh)"
        warn "no checksum at $url.sha256 — skipping verification"
        return 0
    fi
    # Compare the hash only; the filename column is informational.
    expected="$(awk '{print $1; exit}' "$dest.sha256")"
    actual="$(sha256sum "$dest" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] \
        || err "checksum mismatch for $url (expected ${expected:-none}, got $actual)"
    log "sha256 OK: $actual"
}

# --- locate the config files (bundle layout) ---
# BUNDLE ends up pointing at a directory laid out like the release bundle:
#   airlockd (optional here), modprobe-airlock.conf,
#   etc/systemd/system/airlockd.service, etc/samba/smb.conf,
#   etc/avahi/services/airlock.service, etc/udev/rules.d/99-airlock.rules
#
# BASH_SOURCE is empty when the script arrives on stdin (curl | bash), so
# only trust it when it names a real file.
SELF="${BASH_SOURCE[0]:-}"
SRC_DIR=""
if [[ -n "$SELF" && -f "$SELF" ]]; then
    SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
fi

BUNDLE=""
if [[ -n "$SRC_DIR" && -f "$SRC_DIR/etc/samba/smb.conf" ]]; then
    BUNDLE="$SRC_DIR"
    log "using config files from local bundle: $BUNDLE"
elif [[ -n "$SRC_DIR" && -d "$SRC_DIR/../image/pi-gen/stage-airlock" ]]; then
    # Repo checkout: assemble the bundle layout from the pi-gen stage,
    # exactly like the release workflow does.
    STAGE="$SRC_DIR/../image/pi-gen/stage-airlock"
    BUNDLE="$TMP/bundle"
    install -D -m 0644 "$STAGE/01-airlockd/files/etc/systemd/system/airlockd.service" "$BUNDLE/etc/systemd/system/airlockd.service"
    install -D -m 0644 "$STAGE/02-samba/files/etc/samba/smb.conf"                     "$BUNDLE/etc/samba/smb.conf"
    install -D -m 0644 "$STAGE/03-avahi/files/etc/avahi/services/airlock.service"     "$BUNDLE/etc/avahi/services/airlock.service"
    install -D -m 0644 "$STAGE/04-udev/files/etc/udev/rules.d/99-airlock.rules"       "$BUNDLE/etc/udev/rules.d/99-airlock.rules"
    install -D -m 0644 "$SRC_DIR/modprobe-airlock.conf"                               "$BUNDLE/modprobe-airlock.conf"
    log "using config files from repo checkout: $(cd "$STAGE" && pwd)"
else
    resolve_version
    log "installing version: ${_bold}$VERSION${_reset}"
    NAME="airlock-${VERSION}-bundle.tar.gz"
    fetch_verified "https://github.com/$REPO/releases/download/$VERSION/$NAME" "$TMP/$NAME"
    tar -xzf "$TMP/$NAME" -C "$TMP"
    BUNDLE="$TMP/airlock-${VERSION}"
fi
for f in etc/systemd/system/airlockd.service etc/samba/smb.conf \
         etc/avahi/services/airlock.service etc/udev/rules.d/99-airlock.rules \
         modprobe-airlock.conf; do
    [[ -f "$BUNDLE/$f" ]] || err "bundle is missing $f"
done

# --- install apt packages ---
log "installing prerequisite packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    samba samba-common-bin \
    avahi-daemon libnss-mdns \
    exfatprogs ntfs-3g dosfstools e2fsprogs hfsprogs \
    gdisk parted util-linux \
    xz-utils \
    ca-certificates curl

# --- get the binary ---
# Precedence: AIRLOCK_LOCAL_BINARY > AIRLOCK_BINARY_URL > the bundle's
# airlockd > the release tarball (repo checkout without a local binary).
if [[ -n "$LOCAL_BINARY" ]]; then
    log "using local binary: $LOCAL_BINARY"
    [[ -x "$LOCAL_BINARY" ]] || err "$LOCAL_BINARY is not executable"
    cp "$LOCAL_BINARY" "$TMP/airlockd"
elif [[ -n "$BINARY_URL" || ! -f "$BUNDLE/airlockd" ]]; then
    if [[ -n "$BINARY_URL" ]]; then
        fetch_verified "$BINARY_URL" "$TMP/airlockd.tar.gz" optional
    else
        resolve_version
        log "installing version: ${_bold}$VERSION${_reset}"
        fetch_verified "https://github.com/$REPO/releases/download/$VERSION/airlockd-${VERSION}-linux-arm64.tar.gz" \
            "$TMP/airlockd.tar.gz"
    fi
    tar -xzf "$TMP/airlockd.tar.gz" -C "$TMP" airlockd
else
    cp "$BUNDLE/airlockd" "$TMP/airlockd"
fi
[[ -x "$TMP/airlockd" ]] || err "airlockd binary is missing or not executable"

# --- install binary ---
log "installing binary to $PREFIX/bin/airlockd"
install -D -m 0755 "$TMP/airlockd" "$PREFIX/bin/airlockd"

# --- systemd unit ---
# The shipped unit points at /usr/local/bin; follow AIRLOCK_PREFIX.
log "installing systemd unit (with sandbox)"
sed "s|^ExecStart=/usr/local/bin/airlockd|ExecStart=${PREFIX}/bin/airlockd|" \
    "$BUNDLE/etc/systemd/system/airlockd.service" > "$TMP/airlockd.service"
install -D -m 0644 "$TMP/airlockd.service" /etc/systemd/system/airlockd.service

# --- udev rule ---
log "installing udev rule"
install -D -m 0644 "$BUNDLE/etc/udev/rules.d/99-airlock.rules" /etc/udev/rules.d/99-airlock.rules

# --- Samba base config ---
if [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.airlock-backup ]]; then
    log "backing up existing /etc/samba/smb.conf → /etc/samba/smb.conf.airlock-backup"
    cp -a /etc/samba/smb.conf /etc/samba/smb.conf.airlock-backup
fi

log "installing samba base config"
install -D -m 0644 "$BUNDLE/etc/samba/smb.conf" /etc/samba/smb.conf

# Dynamic share include — owned by airlockd, never overwritten here.
mkdir -p /etc/samba/smb.conf.d
touch /etc/samba/smb.conf.d/airlock.conf
chmod 0644 /etc/samba/smb.conf.d/airlock.conf

# --- Avahi service ---
log "installing avahi service advertisement"
install -D -m 0644 "$BUNDLE/etc/avahi/services/airlock.service" /etc/avahi/services/airlock.service

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
    # this installer on a writable root. Turn it off so it stops adding
    # ~2 s to every boot. (The pi-gen image keeps it: there it's how Pi
    # Imager's settings get applied.)
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
    install -D -m 0644 "$BUNDLE/modprobe-airlock.conf" /etc/modprobe.d/modprobe-airlock.conf
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
