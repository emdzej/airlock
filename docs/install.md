# Installing Airlock on a Raspberry Pi

Two ways to get Airlock onto a Pi:

- **[Flash the image](#flash-the-image)** — a ready-made Raspberry Pi OS
  Lite (Trixie, 64-bit) image with Airlock, a read-only root and the
  fast-boot tweaks baked in. Attached to every release from `0.4.0`.
- **[Install on an existing Pi](#quick-install-existing-pi)** — one
  command on top of Raspberry Pi OS Lite (Bookworm or Trixie).

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
Raspberry Pi 4. The Pi 5 is untested (and its header GPIO sits on a
different `gpiochip`, so the button / LED won't work there as-is).

## Flash the image

Every release from `0.4.0` ships `airlock-<version>-linux-arm64.img.xz`
plus a `.sha256` on the
[releases page](https://github.com/emdzej/airlock/releases).

1. **Download and verify:**

   ```sh
   V=0.4.0
   curl -fsSLO "https://github.com/emdzej/airlock/releases/download/$V/airlock-$V-linux-arm64.img.xz"
   curl -fsSLO "https://github.com/emdzej/airlock/releases/download/$V/airlock-$V-linux-arm64.img.xz.sha256"
   shasum -a 256 -c "airlock-$V-linux-arm64.img.xz.sha256"   # sha256sum -c on Linux
   # Optional — check it was built by this repo's release workflow:
   gh attestation verify "airlock-$V-linux-arm64.img.xz" --repo emdzej/airlock
   ```

2. **Flash with [Raspberry Pi Imager](https://www.raspberrypi.com/software/):**
   *Choose OS → Use custom* → pick the `.img.xz`, choose the SD card, then
   **edit the OS customisation settings** before writing:
   - **Services → Enable SSH → Allow public-key authentication only**, and
     paste your public key. **Do this** — the image ships with password
     SSH turned off, so without a key you can only log in on the local
     console. Picking *Use password authentication* instead turns password
     SSH back on.
   - Username / password: any user works. The built-in `airlock` account
     (UID 1000) stays the Samba share owner either way.
   - Wi-Fi (SSID, password, country) if the Pi isn't on Ethernet, and
     optionally hostname and locale.

3. **Boot** the Pi and open `http://airlock.local/` (or the hostname you
   set).

What's different from a stock Pi OS Lite:

- **Read-only root.** `/` is a tmpfs overlay (`overlayroot`): every
  write is discarded at reboot, so a power yank can't corrupt the OS.
  Your Imager settings live in cloud-init's `user-data` / `network-config`
  on the boot partition and are re-applied on every boot — cloud-init is
  deliberately left enabled for this. SSH host keys are kept stable
  across reboots in `/boot/firmware/airlock/ssh/` (FAT can't hold Unix
  permissions, so anyone with the SD card can read them; delete the
  directory to rotate the keys).
- **Default credentials** `airlock` / `airlock` work on the local console
  only (SSH is key-only). `passwd` on the running system is lost at the
  next reboot — see below for persistent changes.
- The [fast-boot](#optional-faster-boot) service disables and
  `dtoverlay=disable-bt` are already applied (cloud-init excepted).

**Making persistent changes** (password, packages, config files):

```sh
sudo overlayroot-chroot       # shell in the real, writable root filesystem
passwd airlock                # e.g. change the console password
exit                          # back to the overlay; takes effect after reboot
```

Anything you set through Imager (user, password, keys, Wi-Fi) is
re-applied from `/boot/firmware/user-data` / `network-config` on every
boot, overriding such changes — edit those files (or re-run Imager)
instead.

For bigger maintenance (`apt upgrade`), boot once with the overlay off:
append ` overlayroot=disabled` to the single line in
`/boot/firmware/cmdline.txt`, reboot, make your changes, remove it again
and reboot. Upgrading Airlock itself is simplest by re-flashing a newer
image.

## Quick install (existing Pi)

One-liner:

```sh
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash
```

The installer:

1. Downloads the release bundle (`airlock-<version>-bundle.tar.gz`) and
   verifies it against the published `.sha256` — it refuses to continue
   on a mismatch or a missing checksum.
2. Installs required apt packages.
3. Installs the `airlockd` arm64 binary, systemd unit, udev rule, and
   Samba / Avahi configuration from the bundle. These are the very same
   files the image is built from
   ([`image/pi-gen/stage-airlock`](https://github.com/emdzej/airlock/tree/main/image/pi-gen/stage-airlock)).
4. Backs up any existing `/etc/samba/smb.conf` to `/etc/samba/smb.conf.airlock-backup`.
5. Reloads udev + systemd, enables and starts the daemon.

Run from an extracted bundle (`sudo ./install.sh`) it uses the local files
and needs no network beyond apt — handy for offline installs. If you'd
rather inspect the script before running it, download `install.sh` and
`install.sh.sha256` from the release and check them first.

It's idempotent — re-running it upgrades the binary and regenerates the
config without touching state on mounted drives.

### Environment overrides

| Variable                | Purpose                                                             |
|-------------------------|---------------------------------------------------------------------|
| `AIRLOCK_VERSION`       | Install a specific tag (e.g. `0.4.0`) instead of the latest release |
| `AIRLOCK_REPO`          | GitHub repo (default `emdzej/airlock`)                             |
| `AIRLOCK_BINARY_URL`    | Fully override the binary tarball URL (checked against `<url>.sha256` if present) |
| `AIRLOCK_LOCAL_BINARY`  | Path to a locally-built binary — skips download                     |
| `AIRLOCK_PREFIX`        | Install prefix (default `/usr/local`)                               |
| `AIRLOCK_HARDEN_USB`    | `1` to also block HID / CDC-* USB drivers (see "Additional hardening") |
| `AIRLOCK_FAST_BOOT`     | `1` to disable services + BT firmware not needed on a headless appliance |
| `AIRLOCK_DISABLE_WIFI`  | `1` to disable the Wi-Fi radio (only if this Pi is on Ethernet)      |

Pass variables **after** `sudo` — `sudo` resets the environment, so
`AIRLOCK_X=1 curl … | sudo bash` silently drops them. Example — install a
pinned version:

```sh
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh \
  | sudo AIRLOCK_VERSION=0.4.0 bash
```

The bundle checksum is published from `0.4.0` on; to install an older
release, use that release's own `install.sh`
(`…/releases/download/<tag>/install.sh`).

## Manual install

If you'd rather not pipe a script into `sudo bash`, or you want to see each
step, install from the release bundle by hand. The bundle is the single
source of truth for every config file — the same files the image is built
from — so nothing below is copy-pasted config that can drift.

### 1. Install packages

```sh
sudo apt-get update
sudo apt-get install -y \
    samba samba-common-bin \
    avahi-daemon libnss-mdns \
    exfatprogs ntfs-3g dosfstools e2fsprogs hfsprogs \
    gdisk parted xz-utils
```

### 2. Download, verify and unpack the bundle

Replace `0.4.0` with the release tag you want (see the
[releases page](https://github.com/emdzej/airlock/releases)).

```sh
V=0.4.0
curl -fsSLO "https://github.com/emdzej/airlock/releases/download/$V/airlock-$V-bundle.tar.gz"
curl -fsSLO "https://github.com/emdzej/airlock/releases/download/$V/airlock-$V-bundle.tar.gz.sha256"
sha256sum -c "airlock-$V-bundle.tar.gz.sha256"
tar -xzf "airlock-$V-bundle.tar.gz"
cd "airlock-$V"
```

The bundle contains:

| Bundle path | Installs to | Source in the repo |
|---|---|---|
| `airlockd` | `/usr/local/bin/airlockd` | built from `cmd/airlockd` |
| `etc/systemd/system/airlockd.service` | same path under `/` | `image/pi-gen/stage-airlock/01-airlockd/files/` |
| `etc/samba/smb.conf` | same path under `/` | `image/pi-gen/stage-airlock/02-samba/files/` |
| `etc/avahi/services/airlock.service` | same path under `/` | `image/pi-gen/stage-airlock/03-avahi/files/` |
| `etc/udev/rules.d/99-airlock.rules` | same path under `/` | `image/pi-gen/stage-airlock/04-udev/files/` |
| `modprobe-airlock.conf` | `/etc/modprobe.d/` (optional, see [hardening](#_1-block-non-storage-usb-device-classes)) | `scripts/` |
| `install.sh` | — (the automated version of these steps) | `scripts/` |

### 3. Copy the files into place

```sh
sudo install -D -m 0755 airlockd /usr/local/bin/airlockd
sudo install -D -m 0644 etc/systemd/system/airlockd.service /etc/systemd/system/airlockd.service
sudo install -D -m 0644 etc/udev/rules.d/99-airlock.rules   /etc/udev/rules.d/99-airlock.rules
sudo install -D -m 0644 etc/avahi/services/airlock.service  /etc/avahi/services/airlock.service

# Samba: keep a copy of the original config (once — don't overwrite it on re-runs).
[ -f /etc/samba/smb.conf.airlock-backup ] || sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.airlock-backup
sudo install -D -m 0644 etc/samba/smb.conf /etc/samba/smb.conf
sudo mkdir -p /etc/samba/smb.conf.d
sudo touch /etc/samba/smb.conf.d/airlock.conf
```

What they do:

- **`airlockd.service`** runs the daemon as root with a seccomp / prctl /
  capability sandbox (see [hardening](#additional-hardening-optional)).
  If you put the binary somewhere other than `/usr/local/bin`, edit
  `ExecStart=` to match.
- **`99-airlock.rules`** tags USB block devices so `airlockd`'s netlink
  listener picks them up. Native SD-card devices (`mmcblk*`) are
  deliberately excluded — the Pi's own boot media must never be exposed
  over SMB.
- **`smb.conf`** is the guest-only, SMB3-only base config, restricted to
  LAN address ranges. It `include`s `/etc/samba/smb.conf.d/airlock.conf`,
  which `airlockd` rewrites on every drive change before calling
  `smbcontrol reload-config` — no Samba restart on plug or unplug.
- **`airlock.service`** (Avahi) advertises `_smb._tcp`, `_http._tcp`,
  `_airlock._tcp` (used by the [companion app](/companion)) and a
  `_device-info._tcp` record that gives the host a Mac Pro icon in
  Finder's sidebar.

### 4. Start

```sh
sudo mkdir -p /mnt/airlock
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl enable smbd airlockd avahi-daemon
sudo systemctl restart smbd
sudo systemctl reload avahi-daemon
sudo systemctl start airlockd
```

### 5. Verify

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
  block devices are candidates (`ID_BUS=usb`), and the daemon also refuses
  any disk that backs a mount outside `/mnt/airlock` (`/`, `/boot/firmware`,
  overlayroot's lower directory) or active swap, so a Pi booted from a
  USB SSD can't wipe its own OS disk.
- Only one destructive operation per device at a time — a second request
  gets `409 busy` instead of racing the first.
- Type-to-confirm uses the drive's current label (or `FLASH` for
  unlabeled media) to slow down accidental clicks.
- For uncompressed images the daemon refuses upfront if the file is
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
laptop. Out of the box:

- Mounts always use `nosuid,nodev,noexec`; nothing from the media is ever
  auto-executed.
- The daemon refuses to touch the disk the OS runs from (anything backing
  `/`, `/boot/firmware` or swap), even when that disk is USB-attached.
- The daemon runs with a seccomp / prctl / capability sandbox:
  `NoNewPrivileges`, `LockPersonality`, `RestrictSUIDSGID`,
  `RestrictAddressFamilies`, `RestrictNamespaces`, `RestrictRealtime`,
  `ProtectHostname`, `MemoryDenyWriteExecute`,
  `SystemCallArchitectures=native`, a `SystemCallFilter` denying the
  `@clock @cpu-emulation @debug @module @obsolete @reboot @swap` groups,
  and a `CapabilityBoundingSet` without `CAP_SYS_MODULE`, `CAP_SYS_BOOT`,
  `CAP_SYS_TIME`, `CAP_SYS_PTRACE`, `CAP_NET_ADMIN`, `CAP_NET_RAW`,
  `CAP_BPF`, `CAP_PERFMON`, `CAP_SYSLOG`. Mount-namespace-inducing
  directives (`ProtectSystem`, `PrivateTmp`, `PrivateDevices`, …) are
  deliberately excluded so mounts propagate to `smbd`.
- **Samba** only speaks SMB3, only on port 445 (no NetBIOS), and only to
  loopback, RFC 1918, link-local and IPv6 ULA / link-local addresses
  (`hosts allow` in `smb.conf`) — a port-forward or a routable IPv6
  address can't expose the guest shares to the internet.
- **Web UI / API** requests are checked in the browser-facing layer, since
  there's no login:
  - `POST` / `DELETE` requests a browser marks as cross-origin
    (`Sec-Fetch-Site` / `Origin`) are rejected with `403`, so a web page
    you visit can't format a drive behind your back. `curl` and the macOS
    companion don't send those headers and are unaffected.
  - Requests whose `Host` header isn't an IP address, a single-label name
    (`airlock`), or a LAN-only name (`*.local`, `.lan`, `.home`,
    `.home.arpa`, `.internal`, `.localdomain`, `.fritz.box`) get `421`.
    That blocks DNS-rebinding attacks. If you reach the Pi through your
    own DNS name, allow it explicitly (comma-separated):

    ```sh
    sudo systemctl edit airlockd
    # add:
    #   [Service]
    #   Environment=AIRLOCK_ALLOWED_HOSTS=files.example.net
    sudo systemctl restart airlockd
    ```

    On the [flashed image](#flash-the-image) `/etc` is on the tmpfs
    overlay, so write the drop-in inside `sudo overlayroot-chroot`
    instead (`/etc/systemd/system/airlockd.service.d/allowed-hosts.conf`)
    and reboot.

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
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh \
  | sudo AIRLOCK_HARDEN_USB=1 bash

# Or apply to an existing airlock install, from an extracted bundle:
sudo install -D -m 0644 modprobe-airlock.conf /etc/modprobe.d/modprobe-airlock.conf
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

The [flashable image](#flash-the-image) ships with `overlayroot=tmpfs` —
the OS partition is read-only and any writes go to RAM, discarded on
reboot. If you want the same on an existing Raspberry Pi OS install:

```sh
sudo apt-get install -y overlayroot
echo 'overlayroot="tmpfs"' | sudo tee /etc/overlayroot.conf
sudo update-initramfs -u
sudo reboot
```

Configure everything (Wi-Fi, users, SSH keys, Airlock options) **before**
enabling it — afterwards, changes need `sudo overlayroot-chroot` or a boot
with ` overlayroot=disabled` appended to `/boot/firmware/cmdline.txt` (see
[Flash the image](#flash-the-image)). The FAT `/boot/firmware` partition
stays writable. Expect the SSH host keys to change on every boot (every
boot is a "first boot" to systemd); the image avoids that with a small
unit you can copy:
[`stage-airlock/07-ssh-host-keys`](https://github.com/emdzej/airlock/tree/main/image/pi-gen/stage-airlock/07-ssh-host-keys).

## Optional: faster boot

An unmodified Raspberry Pi OS Lite Trixie on a Pi 4 boots in ~25 s to
first SMB. Measurements from the reference hardware:

| Configuration | Boot to `multi-user.target` |
|---|---|
| Stock Pi OS Lite Trixie | ~24.0 s |
| + `AIRLOCK_FAST_BOOT=1` (services + `disable-bt`) | ~14.2 s |
| + `AIRLOCK_DISABLE_WIFI=1` (Ethernet only) | ~13.7 s |
| Booting from USB 3 SSD instead of SD | ~8–10 s (untested here) |

The installer applies the first two if you set the env vars (the
[image](#flash-the-image) already has fast-boot applied):

```sh
# Enable fast-boot at install time (safe on any Pi — never touches Wi-Fi):
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh \
  | sudo AIRLOCK_FAST_BOOT=1 bash

# If you're on Ethernet and don't need Wi-Fi at all, add DISABLE_WIFI too.
# The installer refuses if eth0 isn't up — it won't orphan your Pi.
curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh \
  | sudo AIRLOCK_FAST_BOOT=1 AIRLOCK_DISABLE_WIFI=1 bash
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
installer. The image keeps cloud-init enabled: there it's what applies
Raspberry Pi Imager's settings on every boot.

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

Pi 4 only for now: the daemon uses `/dev/gpiochip0`, which is the header
GPIO on a Pi 4 but not on a Pi 5.

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
to remove drives. If a file on a drive is still open (an SMB client
mid-copy, say), that drive is **not** force-unmounted: it stays mounted
and the LED stays solid — close the file and press again.

The daemon runs fine without any GPIO wiring — the button and LED are
optional convenience hardware.

## Uninstall

For an installer-based install (on the flashed image, just re-flash):

```sh
sudo systemctl disable --now airlockd

# Eject everything first — unmount whatever is still under /mnt/airlock.
for m in $(findmnt -rn -o TARGET | grep '^/mnt/airlock/'); do sudo umount "$m"; done

sudo rm -f /etc/systemd/system/airlockd.service \
           /etc/udev/rules.d/99-airlock.rules \
           /etc/avahi/services/airlock.service \
           /etc/modprobe.d/modprobe-airlock.conf \
           /usr/local/bin/airlockd \
           /etc/samba/smb.conf.d/airlock.conf
sudo rm -rf /etc/systemd/system/airlockd.service.d   # drop-ins, if any
sudo rmdir /mnt/airlock 2>/dev/null || true

# Restore original Samba config, if present.
if [ -f /etc/samba/smb.conf.airlock-backup ]; then
    sudo mv /etc/samba/smb.conf.airlock-backup /etc/samba/smb.conf
fi

sudo systemctl daemon-reload
sudo udevadm control --reload
sudo systemctl restart smbd
sudo systemctl reload avahi-daemon
```

If you used `AIRLOCK_PREFIX`, remove `<prefix>/bin/airlockd` instead.

**Undo the optional tweaks** (only the ones you enabled):

```sh
# AIRLOCK_FAST_BOOT=1 — unmask console units, re-enable cloud-init and
# whichever services you want back (e.g. bluetooth, apt-daily timers).
sudo systemctl unmask keyboard-setup.service console-setup.service
sudo rm -f /etc/cloud/cloud-init.disabled
sudo systemctl enable bluetooth.service hciuart.service \
    apt-daily.timer apt-daily-upgrade.timer NetworkManager-wait-online.service

# AIRLOCK_FAST_BOOT=1 / AIRLOCK_DISABLE_WIFI=1 — drop the firmware overlays.
sudo sed -i '/^dtoverlay=disable-bt$/d; /^dtoverlay=disable-wifi$/d' /boot/firmware/config.txt

# AIRLOCK_HARDEN_USB=1 — the modprobe file is removed above; re-enumerate:
sudo systemctl restart systemd-udevd

sudo reboot
```

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

**Format or eject fails with "busy" (`409`).**
Either another operation on the same device is still running (format,
flash, dump, fsck — one at a time per device), or a file on the drive is
still open. Eject withdraws the share from Samba first and then unmounts
without `umount -l`, so an open file makes it fail rather than leave a
half-detached mount; the drive stays mounted. Close the file on the client
(or wait for the copy to finish) and retry. To see who holds it:
`sudo fuser -vm /mnt/airlock/<share>`.

**Web UI / API answers `421 unrecognised Host header`.**
You're reaching the Pi through a DNS name that isn't `.local` / `.lan` /
`.home` / `.home.arpa` / `.internal` / `.localdomain` / `.fritz.box`, an IP
address, or a bare hostname. Add it to `AIRLOCK_ALLOWED_HOSTS` — see
[Additional hardening](#additional-hardening-optional).

**Web UI actions fail with `403 cross-origin request refused`.**
The browser reported the request as coming from another site — e.g. a
page or extension posting to the Pi. Open the UI directly at
`http://<host>.local/` and retry. Scripts using `curl` aren't affected.

**SMB clients can't connect from outside the LAN / over a routable IPv6
address.** By design: `smb.conf` only admits private, link-local and ULA
addresses. Edit `hosts allow` in `/etc/samba/smb.conf` if you really need
more (and `sudo systemctl restart smbd`).

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
