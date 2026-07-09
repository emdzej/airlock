# Changelog

All notable changes to Airlock are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project uses semantic versioning starting at 0.x — pre-1.0 breaking
changes are allowed between minor versions.

## [0.2.0] — 2026-07-09

Hardware verification + hardening + boot-time tuning pass. All 0.1.0
functionality still applies; this release focuses on making the appliance
faster to boot, safer to compromise, and more visible in the Devices tab.

### Added

- **Dump a device to a disk image** (new). Devices tab gets a **Dump…**
  button; pick a compression (xz / gz / none) and the browser streams
  the raw block device down as a downloadable image with a generated
  filename (`airlock-<label>-<date>.img[.xz|.gz]`). Read-only op —
  `sync()` first, then `os.Open("/dev/<parent>")`, pipe through the
  compressor (`xz -c -T 0` for parallel or stdlib `compress/gzip`),
  write straight to the response body. No unmount, so SMB sessions
  aren't disturbed. Endpoint: `GET /api/devices/{parent}/dump?compression=…`.
- **fsck per partition** (new). Devices tab gets a **Check** button on
  every partition with a supported filesystem. Modal picks Check
  (read-only) or Repair (auto-fix, `-p` / `-a` / `-y` per tool),
  unmounts, runs `e2fsck` / `fsck.vfat` / `fsck.exfat` / `ntfsfix` /
  `fsck.hfsplus`, streams stdout+stderr live via SSE into a scrollable
  log in the modal, remounts. Endpoint:
  `POST /api/partitions/{name}/fsck?mode=check|repair`.
- **`stage-airlock/06-fast-boot`**: pi-gen sub-stage that bakes the
  same service disables + `dtoverlay=disable-bt` we ship in
  `AIRLOCK_FAST_BOOT=1` directly into the image. Fresh flashes boot in
  ~14 s without needing the installer flag.
- **Release workflow now builds `.img.xz`**: tagging `x.y.z` now runs
  a second CI job (~45 min) that clones pi-gen inside GitHub Actions,
  syncs `stage-airlock/`, produces the flashable image, and attaches
  `airlock-<tag>-linux-arm64.img.xz` + sha256 to the same GitHub
  Release alongside the binary tarball + install bundle.
- **Flash OS images to a drive** (new). Devices tab gets a **Flash…**
  button; the modal takes a `.img`, `.img.xz`, or `.img.gz` file, streams
  the upload through the appropriate decompressor (`xz -dc` or stdlib
  `compress/gzip`) straight onto `/dev/<parent>` in 4 MB blocks with
  per-500 ms SSE progress events. Zero intermediate storage — a 3 GB Pi
  OS image never lands on the airlock SD, only on the target. Adds
  `xz-utils` to the installer's package list and the pi-gen stage.
  Endpoint: `POST /api/devices/{parent}/flash?compression=none|xz|gz`
  (raw body, `text/event-stream` response). Safety-gated to USB
  devices, uses the same quarantine mechanism as format so the daemon
  doesn't auto-mount the fresh partition table mid-write.
- **Mount button** on the Devices tab for USB partitions that have a
  supported filesystem but aren't currently mounted by airlock. Backed
  by `POST /api/partitions/{name}/mount` — safety-gated to USB-attached
  devices, fires `udevadm trigger --action=add` and the daemon's normal
  event handler picks up the mount.
- **`AIRLOCK_FAST_BOOT=1` installer flag.** Disables services not needed
  on a headless appliance (bluetooth, hciuart, triggerhappy, ModemManager,
  unused Samba flavours `nmbd`/`winbind`/`samba-ad-dc`, `apt-daily`
  timers, `e2scrub`, `dphys-swapfile`, `NetworkManager-wait-online`,
  `rpi-eeprom-update`); masks `keyboard-setup` and `console-setup`;
  disables cloud-init post-first-boot; adds `dtoverlay=disable-bt` to
  `/boot/firmware/config.txt` to skip Bluetooth radio init.
- **`AIRLOCK_DISABLE_WIFI=1` installer flag.** Adds `dtoverlay=disable-wifi`
  after checking that `eth0` is up — refuses to run if not, so it can't
  accidentally orphan a Wi-Fi-only Pi.
- **`AIRLOCK_HARDEN_USB=1` installer flag** plus `scripts/modprobe-airlock.conf`.
  Blocks HID (keyboards / mice) and CDC-* (USB Ethernet / serial) driver
  binding at attach time while leaving USB mass storage alone —
  neutralizes "BadUSB" / "USB Rubber Ducky" attacks against the console.
- **systemd seccomp + prctl sandbox** on `airlockd.service`:
  `NoNewPrivileges`, `LockPersonality`, `RestrictSUIDSGID`,
  `RestrictRealtime`, `RestrictNamespaces`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`.
  Mount-namespace-inducing directives are deliberately excluded (see
  Fixed below).
- **New docs sections** in `docs/install.md`: **Optional: faster boot**
  (with per-service explanation, measured impact, and a manual recipe)
  and **Additional hardening** (systemd sandbox + optional USB blocklist).
- Devices tab payload now includes `can_mount` and `can_relabel` flags
  per partition, so the UI shows only the actions that make sense.

### Fixed

- **SMB shares appeared empty when the systemd sandbox created a private
  mount namespace.** `ProtectSystem=strict` + `ReadWritePaths` bind-mounted
  `/mnt/airlock` into the service's own namespace as slave, so mounts
  airlockd made were invisible to smbd running in the host namespace.
  `MountFlags=shared` didn't fix it (a slave mount only propagates
  host→service, not back). Sandbox reduced to seccomp/prctl only —
  no private mount namespace, mounts propagate correctly.
- Format operation "device or resource busy" during `wipefs` — added a
  device quarantine so the daemon ignores auto-mount events for the
  target device between unmount and mkfs.
- `udevadm trigger --subsystem-match=block` no longer accidentally
  matches the Pi's own boot media (`mmcblk*`) — the udev rule requires
  `ID_BUS=usb`, and every mount pass additionally cross-checks
  `/proc/self/mountinfo` before touching a device.
- Windows-friendly Copy button on the Mounts tab now sends
  `\\host\share` on Windows and `smb://host/share` everywhere else.

### Boot-time measurements (Pi 4 / Trixie reference hardware)

| Configuration | `multi-user.target` reached |
|---|---|
| Stock Pi OS Lite Trixie | 24.0 s |
| + `AIRLOCK_FAST_BOOT=1` | 14.2 s |
| + `AIRLOCK_DISABLE_WIFI=1` | 13.7 s |

## [0.1.0] — 2026-07-09

First internal snapshot. Airlock is a network card reader appliance for
the Raspberry Pi 4: plug in USB media, expose it over SMB and a small
web UI, manage it (browse / upload / format / relabel) from any device
on your LAN.

### Added — daemon

- Netlink udev subscription that auto-mounts USB block devices under
  `/mnt/airlock/<name>` with per-filesystem mount options for FAT32,
  exFAT, NTFS (kernel `ntfs3`), ext2/3/4, HFS+ (read-only), and ISO9660.
- Multi-partition drives: each partition becomes its own share; hybrid-ISO
  layouts are handled by skipping partitions when the parent disk is
  already mounted as a filesystem.
- Read-only detection: media flagged read-only in `/sys/class/block/*/ro`
  (write-protect switch, iso9660, etc.) is mounted RO and refuses writes
  via HTTP / SMB.
- Dynamic Samba shares: `airlockd` regenerates a single include file at
  `/etc/samba/smb.conf.d/airlock.conf` on each drive change and calls
  `smbcontrol reload-config` — no `smbd` restart.
- Startup state recovery: on daemon restart, stale `/mnt/airlock/*`
  mounts are force-unmounted and `udevadm trigger --action=add
  --subsystem-match=block` re-fires ADD events for currently attached
  devices.
- Owner lookup: the guest Samba `force user` is resolved at start from
  UID 1000, so the same binary works on both `pi-gen`-built images
  (`airlock`) and generic Raspberry Pi OS installs (`pi`, `emdzej`, …).
- Physical GPIO controls: button on GPIO 17 (BCM) triggers a global
  eject; LED on GPIO 27 reflects state (off / solid / fast-blink busy)
  via a small state machine. Fails soft when no chip / no wiring.
- Avahi advertisement of `_smb._tcp`, `_http._tcp` and
  `_device-info._tcp` — the last one carries `model=TimeCapsule6,106`
  so macOS Finder renders the host as a network drive instead of a
  generic computer.
- Every mount carries `nosuid,nodev,noexec` — no binary from the media
  can execute, gain privileges, or open a device node.
- `sync()`-on-shutdown; no automatic unmount on shutdown so a systemd
  restart never yanks a user's data.

### Added — HTTP UI (`http://<host>.local/`)

- **Mounts** tab: current shares with per-share Eject, clickable
  `smb://…` links, and a Copy button.
- **Devices** tab: enumerates every USB block device via `lsblk -bJ`,
  showing model, vendor, serial, size, partition-table type, and every
  partition (mounted or not). Per-device Eject / Format… actions,
  per-partition Rename (volume label).
- **File browser** at `/drives/{share}/`: breadcrumbs, sort dirs-first,
  download links, delete + rename with type-to-confirm dialogs, mkdir.
  Upload accepts individual files, whole folders (`webkitdirectory`),
  and drag-drop of files or folders — folder tree is preserved on the
  target. One HTTP request per file with per-file progress; the progress
  card has an expandable Details panel showing status of each item.
- **Format** modal (Devices tab): filesystem picker (FAT32 / exFAT /
  NTFS / ext4) auto-selected by size, new-label field with per-FS length
  limits, type-to-confirm safety, SSE-streamed progress
  (`unmount → wipe → partition → rescan → mkfs → done`).
- **Volume relabel** per partition (Devices tab): unmounts, runs the
  FS-specific tool (`fatlabel`, `exfatlabel`, `ntfslabel`, `e2label`),
  triggers udev to remount under the new label.
- Live polling: pages fetch state every 3 s and only touch the DOM when
  the underlying JSON differs — no flashing reloads, scroll/hover state
  preserved.
- Version + GitHub link in the footer of every page.

### Added — packaging & tooling

- `pi-gen` custom stage (`image/pi-gen/stage-airlock/`) producing an
  arm64 Bookworm image with a read-only root (`overlayroot=tmpfs`) and
  all daemon dependencies preinstalled.
- Installer for existing Raspberry Pi OS installs (`scripts/install.sh`):
  idempotent, downloads a matching arm64 binary from GitHub Releases,
  drops the systemd unit / udev rule / Samba / Avahi configuration,
  backs up any existing `smb.conf` before overwriting, enables and
  starts everything.
- Manual install guide (`docs/install.md`) covering prerequisites,
  quick-install one-liner, step-by-step manual install, macOS/Linux/
  Windows client instructions, GPIO wiring diagram, uninstall, and
  troubleshooting.
- GitHub Actions CI (`.github/workflows/ci.yml`): `go vet`, `go test
  -race`, host build, cross-compile arm64, and `shellcheck` on the
  installer.
- GitHub Actions Release (`.github/workflows/release.yml`): triggered
  by any `<major>.<minor>.<patch>` tag (no `v` prefix required),
  publishes `airlockd-<tag>-linux-arm64.tar.gz` + sha256, an offline
  install bundle, and the raw `install.sh` on the GitHub Release.

### Known limitations

- Not tested on Raspberry Pi 5 (would need `ChipName` config override
  for GPIO — Pi 5 uses `gpiochip4`).
- Read-only root is defined in the pi-gen stage but the full image
  build (`make image`) has not yet been round-tripped on a fresh Pi.
- Corporate networks with mDNS filtering or 802.1X-controlled Ethernet
  are intentionally out of scope. Home / small-office LANs only.
- Multi-partition creation, live resize, and encrypted volumes
  (LUKS / BitLocker) are out of scope by design.
