# Installing Airlock on a Raspberry Pi

Airlock is designed to run on an existing Raspberry Pi (Bookworm or Trixie).
For fresh installs a pi-gen image will eventually ship — until then, install
on top of Raspberry Pi OS Lite.

## Prerequisites

- **Hardware:** Raspberry Pi 4 (2 GB or more), 64-bit
- **OS:** Debian 12 (Bookworm) or Debian 13 (Trixie); 64-bit Raspberry Pi OS Lite works.
- **Access:** SSH or a local terminal with `sudo`.
- **Network:** Wi-Fi or Ethernet. mDNS (`.local` resolution) must work for the
  hostname; on tightly-controlled corporate Wi-Fi this may be blocked, in
  which case use the Pi's IP directly.
- **First user:** the first non-root Unix user must have UID 1000. This is
  the default when you provision the Pi via Raspberry Pi Imager. The Samba
  guest identity is mapped to this user.

Airlock has been verified on Raspberry Pi OS Trixie (kernel 6.18) on a
Raspberry Pi 4.

## Quick install (recommended)

One-liner:

```sh
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash
```

The installer:

1. Installs required apt packages.
2. Downloads the matching `airlockd` arm64 binary from the latest release.
3. Drops the systemd unit, udev rule, and Samba / Avahi configuration.
4. Backs up any existing `/etc/samba/smb.conf` to `/etc/samba/smb.conf.airlock-backup`.
5. Reloads udev + systemd, enables and starts the daemon.

It's idempotent — re-running it upgrades the binary and regenerates the
config without touching state on mounted drives.

### Environment overrides

| Variable                | Purpose                                                             |
|-------------------------|---------------------------------------------------------------------|
| `AIRLOCK_VERSION`       | Install a specific tag (e.g. `0.2.0`) instead of the latest release |
| `AIRLOCK_REPO`          | GitHub repo (default `emdzej/airlock`)                             |
| `AIRLOCK_BINARY_URL`    | Fully override the tarball URL                                      |
| `AIRLOCK_LOCAL_BINARY`  | Path to a locally-built binary — skips download                     |
| `AIRLOCK_PREFIX`        | Install prefix (default `/usr/local`)                               |
| `AIRLOCK_HARDEN_USB`    | `1` to also block HID / CDC-* USB drivers (see "Additional hardening") |
| `AIRLOCK_FAST_BOOT`     | `1` to disable services + BT firmware not needed on a headless appliance |
| `AIRLOCK_DISABLE_WIFI`  | `1` to disable the Wi-Fi radio (only if this Pi is on Ethernet)      |

Example — install a pinned version:

```sh
AIRLOCK_VERSION=0.2.0 \
  curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo -E bash
```

## Manual install

If you'd rather not pipe a script into `sudo bash`, or you want to see each
step, do the following.

### 1. Install packages

```sh
sudo apt-get update
sudo apt-get install -y \
    samba samba-common-bin \
    avahi-daemon libnss-mdns \
    exfatprogs ntfs-3g dosfstools e2fsprogs hfsprogs \
    gdisk parted
```

### 2. Download the binary

Replace `0.2.0` with the release tag you want. See the
[releases page](https://github.com/emdzej/airlock/releases) for available
tags.

```sh
V=0.2.0
curl -fsSL "https://github.com/emdzej/airlock/releases/download/$V/airlockd-$V-linux-arm64.tar.gz" \
    | sudo tar -xz -C /usr/local/bin airlockd
sudo chmod 0755 /usr/local/bin/airlockd
```

### 3. Systemd unit

```sh
sudo tee /etc/systemd/system/airlockd.service > /dev/null <<'UNIT'
[Unit]
Description=Airlock daemon
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

[Install]
WantedBy=multi-user.target
UNIT
```

### 4. udev rule

```sh
sudo tee /etc/udev/rules.d/99-airlock.rules > /dev/null <<'UDEV'
SUBSYSTEM=="block", KERNEL=="sd[a-z]*", ENV{ID_BUS}=="usb", ENV{AIRLOCK_MANAGED}="1"
UDEV
```

This tags USB block devices so `airlockd`'s netlink listener picks them up.
Native SD-card devices (`mmcblk*`) are deliberately excluded — the Pi's own
boot media must never be exposed over SMB.

### 5. Samba base config

The current file is backed up before we overwrite it:

```sh
sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.airlock-backup 2>/dev/null || true

sudo tee /etc/samba/smb.conf > /dev/null <<'SMB'
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
    include = /etc/samba/smb.conf.d/airlock.conf
SMB

sudo mkdir -p /etc/samba/smb.conf.d
sudo touch /etc/samba/smb.conf.d/airlock.conf
```

`airlockd` rewrites `/etc/samba/smb.conf.d/airlock.conf` on every drive
change and calls `smbcontrol reload-config` — no Samba restart on plug or
unplug.

### 6. Avahi advertisement

```sh
sudo tee /etc/avahi/services/airlock.service > /dev/null <<'AVAHI'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Airlock on %h</name>
  <service><type>_smb._tcp</type><port>445</port></service>
  <service><type>_http._tcp</type><port>80</port></service>
  <service>
    <type>_device-info._tcp</type>
    <port>0</port>
    <txt-record>model=TimeCapsule6,106</txt-record>
  </service>
</service-group>
AVAHI
```

The `_device-info._tcp` record with `model=TimeCapsule6,106` tells macOS
Finder to render the host as a network drive rather than a generic
"computer" in the Network sidebar.

### 7. Start

```sh
sudo mkdir -p /mnt/airlock
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl enable smbd airlockd avahi-daemon
sudo systemctl restart smbd
sudo systemctl reload avahi-daemon
sudo systemctl start airlockd
```

### 8. Verify

```sh
systemctl status airlockd
curl -sI http://localhost/ | head -1     # expect: HTTP/1.1 200 OK
journalctl -u airlockd -n 20 --no-pager  # sanity-check the startup log
```

## Flashing OS images to a drive

The Devices tab has a **Flash…** action per device. Pick a raw `.img`
or an `.img.xz` / `.img.gz` (Raspberry Pi OS, OpenWRT, Ubuntu, etc.);
airlockd streams the upload straight through an optional decompressor
onto `/dev/<device>`. No intermediate storage — a 3 GB Pi OS image
never lands on the Pi's boot SD, only on the target.

**Workflow:**
1. Plug in a target USB drive or SD-in-USB-reader.
2. Go to `http://<host>.local/devices` → **Flash…** on the target.
3. Pick the image, type the confirmation word, hit **Flash**.
4. Progress shows uploaded bytes + written bytes in real time.
5. When done, the daemon re-scans partitions; anything mountable (FAT,
   NTFS, ext4) appears back on the Mounts tab automatically.

**Safety:**
- Airlock refuses to flash the Pi's own boot media — only USB-attached
  block devices are candidates (`ID_BUS=usb`).
- Type-to-confirm uses the drive's current label (or `FLASH` for
  unlabeled media) to slow down accidental clicks.
- For uncompressed images the installer refuses upfront if the file is
  larger than the target drive.

**Not supported yet:**
- `.zip` archives — extract the `.img` locally first.
- Verify-after-write pass — planned; add `?verify=1` when available.
- Cancellation mid-flash — safer to always complete than leave a
  half-written device.

## Post-install

Plug in a USB drive. Within a few seconds:

- **Web UI:** `http://<hostname>.local/`
- **SMB share:** `smb://<hostname>.local/<label>` (guest access, no password)

The Mounts tab lists shares that are currently exposed; the Devices tab
lists every USB block device, whether mounted or not, with a **Format…**
action per device.

### Connecting

| Client               | How                                                                        |
|----------------------|----------------------------------------------------------------------------|
| macOS Finder         | ⌘K → `smb://<host>.local` → **Connect As: Guest**                          |
| macOS CLI            | `mount_smbfs //guest@<host>.local/<share> /Volumes/<share>` (empty password) |
| Windows Explorer     | `\\<host>\<share>` (may require enabling "insecure guest logons" via GPO)  |
| Linux (Nautilus)     | Files sidebar → Other Locations → `smb://<host>.local/`                    |
| CLI (`smbclient`)    | `smbclient -N //<host>.local/<share>`                                      |

## Additional hardening (optional)

Airlock is designed to be safer than plugging USB storage directly into your
laptop — mounts always use `nosuid,nodev,noexec`, we never auto-execute
anything from the media, and the daemon runs with a seccomp+prctl sandbox
(`NoNewPrivileges`, `LockPersonality`, `RestrictSUIDSGID`,
`RestrictAddressFamilies`, `RestrictNamespaces`, `RestrictRealtime`).
Mount-namespace-inducing directives are deliberately excluded so mounts
propagate to `smbd`.

Two more layers are available if you want them.

### 1. Block non-storage USB device classes

By default the Pi will still enumerate USB keyboards, mice, and USB-Ethernet
adapters if they're plugged in. That's useful (e.g. for a keyboard during
debugging) but it's also the attack surface exploited by "BadUSB" / "USB
Rubber Ducky" devices, where a stick pretends to be a keyboard and types
commands at whatever session is on the console.

To refuse those drivers at attach time — while keeping USB mass storage
working — install the ships-with-the-repo modprobe blocklist:

```sh
# One-liner install (curl-piped install.sh):
AIRLOCK_HARDEN_USB=1 \
  curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo -E bash

# Or apply to an existing airlock install:
curl -fsSL https://raw.githubusercontent.com/emdzej/airlock/main/scripts/modprobe-airlock.conf \
    | sudo tee /etc/modprobe.d/modprobe-airlock.conf > /dev/null
sudo systemctl restart systemd-udevd
sudo reboot   # reboot cleanly re-enumerates every USB device
```

**Trade-off:** you can no longer use a USB keyboard, mouse, or USB-Ethernet
adapter on this Pi. If you rely on any of those (SSH is unaffected — that's
network), leave the blocklist uninstalled.

To remove:

```sh
sudo rm /etc/modprobe.d/modprobe-airlock.conf
sudo systemctl restart systemd-udevd
```

### 2. Read-only root filesystem

The `pi-gen` custom image ships with `overlayroot=tmpfs` — the OS partition
is read-only and any writes go to RAM, discarded on reboot. If you want the
same on an existing Raspberry Pi OS install:

```sh
sudo apt-get install -y overlayroot
echo 'overlayroot="tmpfs"' | sudo tee /etc/overlayroot.conf
sudo update-initramfs -u
sudo reboot
```

Persistent settings (Wi-Fi credentials, hostname) should live on the FAT
`/boot/firmware` partition, which stays writable.

## Optional: faster boot

An unmodified Raspberry Pi OS Lite Trixie on a Pi 4 boots in ~25 s to
first SMB. Measurements from the reference hardware:

| Configuration | Boot to `multi-user.target` |
|---|---|
| Stock Pi OS Lite Trixie | ~24.0 s |
| + `AIRLOCK_FAST_BOOT=1` (services + `disable-bt`) | ~14.2 s |
| + `AIRLOCK_DISABLE_WIFI=1` (Ethernet only) | ~13.7 s |
| Booting from USB 3 SSD instead of SD | ~8–10 s (untested here) |

The installer applies the first two if you set the env vars:

```sh
# Enable fast-boot at install time (safe on any Pi — never touches Wi-Fi):
AIRLOCK_FAST_BOOT=1 \
  curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo -E bash

# If you're on Ethernet and don't need Wi-Fi at all, add DISABLE_WIFI too.
# The installer refuses if eth0 isn't up — it won't orphan your Pi.
AIRLOCK_FAST_BOOT=1 AIRLOCK_DISABLE_WIFI=1 \
  curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo -E bash
```

### What `AIRLOCK_FAST_BOOT=1` does

Disables the following services (none of them affect Airlock or SSH):

- `bluetooth`, `hciuart` — Bluetooth stack + UART attach
- `triggerhappy` (+ its socket) — hotkey daemon, headless-irrelevant
- `ModemManager` — cellular / broadband modem (Pi has neither built-in)
- `nmbd`, `samba-ad-dc`, `winbind` — Samba flavours we don't use;
  `smbd` (which we do use) stays enabled
- `apt-daily.timer`, `apt-daily-upgrade.timer` — background updates
- `e2scrub_reap`, `e2scrub_all.timer` — ext4 quota housekeeping
- `dphys-swapfile` — old-style swapfile (zram is enough on Trixie)
- `NetworkManager-wait-online` — the ~5 s wait for connectivity;
  `smbd` / `avahi` / `airlockd` all bind to `0.0.0.0` and handle a
  slightly-late network cleanly
- `rpi-eeprom-update` — on-demand only, no need to run on every boot
- `keyboard-setup`, `console-setup` — masked (no console anyway)

Also disables cloud-init (touches `/etc/cloud/cloud-init.disabled`)
because it's already done its first-boot job by the time you run the
installer.

Also adds `dtoverlay=disable-bt` to `/boot/firmware/config.txt` — skips
Bluetooth radio init (~1 s of kernel time). Takes effect on next reboot.

### What `AIRLOCK_DISABLE_WIFI=1` does

Adds `dtoverlay=disable-wifi` to `/boot/firmware/config.txt`, disabling
the Wi-Fi radio at firmware level. Takes effect on next reboot.

**Only enable this if the Pi is connected via Ethernet.** The installer
sanity-checks `eth0` is up before writing the config; if not, it aborts
rather than orphaning your Pi.

**Ethernet vs Wi-Fi on Pi 4:** wired Gigabit tops out around 940 Mbps
real; the Wi-Fi 5 radio does ~200–400 Mbps under ideal conditions. If
you're shuffling large files (photo/video card offload), Ethernet also
delivers lower latency and doesn't share airtime with your neighbours.

### Doing it manually

If you'd rather not set env vars, the same effect from a shell:

```sh
# Service disables
sudo systemctl disable --now bluetooth.service hciuart.service \
    triggerhappy.service triggerhappy.socket \
    ModemManager.service \
    nmbd.service samba-ad-dc.service winbind.service \
    apt-daily.timer apt-daily-upgrade.timer \
    e2scrub_reap.service e2scrub_all.timer \
    dphys-swapfile.service \
    NetworkManager-wait-online.service \
    rpi-eeprom-update.service 2>/dev/null

sudo systemctl mask keyboard-setup.service console-setup.service
sudo touch /etc/cloud/cloud-init.disabled

# Firmware overlays (take effect after reboot)
echo 'dtoverlay=disable-bt'   | sudo tee -a /boot/firmware/config.txt
# Only if this Pi is on Ethernet:
echo 'dtoverlay=disable-wifi' | sudo tee -a /boot/firmware/config.txt

sudo reboot
```

### Measure before and after

```sh
systemd-analyze                    # overall time
systemd-analyze blame              # per-service, largest first
systemd-analyze critical-chain     # what blocks what
```

### Don't disable these — they are load-bearing

- `avahi-daemon.service` (mDNS discovery, `airlock.local`)
- `smbd.service` (SMB shares)
- `airlockd.service` (obviously)
- `NetworkManager.service` (or `systemd-networkd`, whichever brings up
  the interface)
- `systemd-timesyncd.service` (log timestamps)
- `ssh.service` (if you rely on SSH — you probably do)

## Optional: GPIO button + LED

Wire a momentary switch to **GPIO 17** (physical pin 11) with the other lead
to ground. Wire an LED to **GPIO 27** (physical pin 13) through a ~330 Ω
resistor, cathode to ground.

```
                       Pi 40-pin header (excerpt)
                       ┌─────────┬─────────┐
                       │ ...     │ ...     │
                   11  │ GPIO 17 │ GPIO 18 │ 12
                   13  │ GPIO 27 │ GND     │ 14
                       │ ...     │ ...     │
                       └─────────┴─────────┘

  Button:  pin 11 (GPIO 17) ── momentary switch ── pin 9 (GND)
  LED:     pin 13 (GPIO 27) ── 330Ω ── LED(+) ── LED(-) ── pin 14 (GND)
```

### LED states

| State                          | Meaning                                     |
|--------------------------------|---------------------------------------------|
| Off                            | No drives mounted                           |
| Solid                          | Drives mounted, safe to press the button    |
| Fast blink (~4 Hz)             | Eject or format in progress; do NOT yank    |

Press the button to trigger a global eject. When the LED goes off, it's safe
to remove drives.

The daemon runs fine without any GPIO wiring — the button and LED are
optional convenience hardware.

## Uninstall

```sh
sudo systemctl stop airlockd
sudo systemctl disable airlockd
sudo rm -f /etc/systemd/system/airlockd.service \
           /etc/udev/rules.d/99-airlock.rules \
           /etc/avahi/services/airlock.service \
           /usr/local/bin/airlockd \
           /etc/samba/smb.conf.d/airlock.conf

# Restore original Samba config, if present.
if [ -f /etc/samba/smb.conf.airlock-backup ]; then
    sudo mv /etc/samba/smb.conf.airlock-backup /etc/samba/smb.conf
fi

sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl restart smbd
```

`/mnt/airlock` and any mounts underneath are left in place; unmount and
remove those manually if you want a fully clean state.

## Troubleshooting

**`airlock.local` doesn't resolve.**
Confirm Avahi is running: `systemctl status avahi-daemon`. On corporate
Wi-Fi networks with mDNS filtering it will silently fail — use the IP
address directly (`http://<ip>/`).

**Web UI works but SMB shows no shares.**
Check `sudo testparm -s` for Samba syntax errors. Confirm `smbd` is
running: `systemctl status smbd`. On Windows, "insecure guest logons" must
be enabled — see Microsoft KB4046019.

**`journalctl -u airlockd` shows repeated "mount failed" errors.**
The USB device's filesystem is unsupported (Airlock supports FAT32, exFAT,
NTFS, ext4 read-write; HFS+ read-only) or the media is corrupted. Try
formatting via the Devices tab.

**Format fails with "Device or resource busy".**
A Samba client (or another process) is still holding the device open.
`airlockd` closes Samba sessions before formatting, but a very quick retry
via the UI usually clears it. Failing that, `sudo fuser -k /dev/sdX` and
retry.

**GPIO init warning at startup.**
The daemon logs a warning and continues if it can't reserve
`/dev/gpiochip0` — usually because nothing is wired. Safe to ignore if
you're not using the physical button.

**Logs:**

```sh
journalctl -u airlockd -f          # daemon
journalctl -u smbd -f              # Samba
journalctl -u avahi-daemon -f      # mDNS / discovery
```
