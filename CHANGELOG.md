# Changelog

All notable changes to Airlock are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project uses semantic versioning starting at 0.x.

## [0.1.0] — 2026-07-09

First public tag. Airlock is a network card reader appliance for the
Raspberry Pi 4: plug in USB media, expose it over SMB and a small web UI,
manage it (browse / upload / format / relabel) from any device on your LAN.

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
- Safety guards against ever exposing the Pi's own boot media: udev rule
  matches only USB `sd*` devices, and every mount pass cross-checks
  `/proc/self/mountinfo` for prior mounts.
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
- `sync()`-on-shutdown; no automatic unmount on shutdown so a systemd
  restart never yanks a user's data.

### Added — HTTP UI (`http://<host>.local/`)

- **Mounts** tab: current shares with per-share Eject, clickable
  `smb://…` links, and a Copy button that puts the platform-appropriate
  form on the clipboard (`\\host\share` on Windows, `smb://…` elsewhere).
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
- **Format** modal (Devices tab) with:
  - filesystem picker (FAT32 / exFAT / NTFS / ext4) auto-selected by
    device size (FAT32 <32 GB, exFAT ≥32 GB);
  - new-label field with per-FS length limits;
  - type-to-confirm safety (matches an existing label, or the literal
    word `FORMAT` if the drive is unlabeled);
  - SSE-streamed progress (`unmount → wipe → partition → rescan → mkfs
    → done`);
  - device quarantine while the operation runs, so the daemon does not
    auto-mount the fresh partition mid-mkfs.
- **Volume relabel** per partition (Devices tab): unmounts, runs the
  FS-specific tool (`fatlabel`, `exfatlabel`, `ntfslabel`, `e2label`),
  triggers udev to remount under the new label.
- Live polling: pages fetch state every 3 s and only touch the DOM when
  the underlying JSON differs — no flashing reloads, scroll/hover state
  preserved.
- Version + GitHub link in the footer of every page.

### Added — security & sandboxing

- `airlockd.service` gets a seccomp + prctl sandbox:
  `NoNewPrivileges`, `LockPersonality`, `RestrictSUIDSGID`,
  `RestrictRealtime`, `RestrictNamespaces`, and
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`.
  Deliberately no `ProtectSystem` / `ProtectHome` / `PrivateTmp` /
  `ReadWritePaths` / `Protect{KernelTunables,KernelModules,ControlGroups}`
  — each of those creates a private mount namespace which would trap
  our mounts away from `smbd` and leave SMB shares empty.
- Every mount already carried `nosuid,nodev,noexec` in 0.1.0; that
  guarantee is now called out in the docs alongside the sandbox.
- Optional USB device-class blocklist (`scripts/modprobe-airlock.conf`)
  refuses HID (keyboards / mice) and CDC-* (USB Ethernet / serial)
  drivers at attach time while leaving USB mass storage alone —
  neutralizes "BadUSB" / "USB Rubber Ducky" attacks against the
  console. Opt-in via `AIRLOCK_HARDEN_USB=1` in the installer or by
  copying the file to `/etc/modprobe.d/`. Documented under
  **Additional hardening** in `docs/install.md`.

### Added — packaging & tooling

- `pi-gen` custom stage (`image/pi-gen/stage-airlock/`) producing an
  arm64 Bookworm image with a read-only root (`overlayroot=tmpfs`) and
  all daemon dependencies preinstalled.
- Installer for existing Raspberry Pi OS installs (`scripts/install.sh`):
  idempotent, downloads a matching arm64 binary from GitHub Releases,
  drops the systemd unit / udev rule / Samba / Avahi configuration,
  backs up any existing `smb.conf` before overwriting, enables and
  starts everything. Environment overrides for version, custom URL,
  local binary path, and install prefix.
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
