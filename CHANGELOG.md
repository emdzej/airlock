# Changelog

All notable changes to Airlock are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project uses semantic versioning starting at 0.x — pre-1.0 breaking
changes are allowed between minor versions.

## [0.4.0] — 2026-09-25

Security and data-safety release that comes out of a full audit of the codebase.
Upgrading is strongly recommended. Nothing in the API was removed: eject
calls can now return `409` when a drive is busy, and drive objects gain an
`ejecting` field.

### Security

- **Symlinks on a drive can no longer reach outside it.** Every file
  operation now goes through Go's `os.Root`, so the kernel checks each
  path component. Before, only downloads checked symlinks. A drive with
  `x -> /etc` could be used to list, upload into, rename or delete files
  anywhere on the Pi, as root.
- **Cross-site request forgery and DNS rebinding are blocked.** Any web
  page opened on the LAN could POST to the unauthenticated API, for
  example to format a drive. Now:
  - Cross-origin POST/DELETE requests are rejected with `403`, using
    Go's `http.CrossOriginProtection`.
  - Requests whose `Host` isn't an IP, a single-label name or a LAN
    suffix (`.local`, `.lan`, `.home.arpa`, …) are rejected with `421`.
  - Extra names can be allowed with `AIRLOCK_ALLOWED_HOSTS`.
  - curl and the companion app send no browser headers and aren't
    affected.
- **The OS disk is refused.** A disk that backs `/`, `/boot/firmware`,
  overlayroot's lower dir, any other mount outside `/mnt/airlock`, or
  active swap is left out of the device list. It can't be formatted,
  flashed, dumped or auto-mounted, which protects a Pi booted from a USB
  SSD. Flash also opens the device with `O_EXCL` as a last line of
  defence.
- **Reserved Samba names are escaped.** A drive labelled `GLOBAL`,
  `homes` or `printers` can no longer inject a Samba `[global]` (or
  other reserved) section. It gets a `-<kernel>` suffix instead.
- **Relabel rejects labels starting with `-`.** These were parsed as
  options by `ntfslabel` and friends.
- **FIFOs on a drive can't hang the daemon.** A named pipe on the drive
  no longer blocks a download forever.
- **Image: SSH is key-only by default.** Pi Imager customisation works
  again: cloud-init is no longer disabled. SSH host keys survive reboots
  on the read-only root.
- **systemd unit hardening, still without a mount namespace:**
  - syscall filter;
  - capability bounding set;
  - `MemoryDenyWriteExecute`;
  - `ProtectHostname`.
- **Samba requires SMB3.** NetBIOS is disabled and access is limited
  to private, link-local and ULA address ranges.
- **`install.sh` verifies downloads.** Everything it downloads is
  checked against the published `.sha256`.
- **Build provenance.** Release artifacts ship with build provenance
  attestations.

### Fixed — data safety

- **Eject never reports "safe to remove" while data is still in flight.**
  - The share is withdrawn from Samba first, so macOS can't reconnect.
  - Samba's file handles are closed and the unmount is retried.
  - If a file is still open, eject returns `409` and the drive stays
    mounted. It used to fall back to `umount -l` and report success.
  - Lazy unmount is now used only when the device has already been
    physically removed.
- **Only one operation runs on a disk at a time.** Format, flash, fsck,
  relabel and dump each take a per-disk lock; a second one returns
  `409`. The disk is quarantined for the whole operation, and a mount
  that was already in progress is waited for, so it can't land
  mid-`mkfs`.
- **fsck and relabel touch only the target partition.** They unmount just
  that partition (siblings stay mounted) and keep the daemon from
  re-mounting it mid-repair.
- **Flashing an `.xz` image:**
  - A failed write no longer hangs forever.
  - A corrupt or truncated `.xz` now fails instead of reporting `done`.
- **A failed upload no longer deletes the file it was overwriting.**
  Uploads are written to a temp file and renamed into place.
- **Operations outlive a closed browser tab.** A running format, flash
  or fsck keeps going, and so does its busy LED, until it finishes.
  Progress events are no longer dropped. airlockd waits for running
  operations on shutdown instead of killing them (`TimeoutStopSec=1h`).
- **Drive-change updates are delivered in order.** Out-of-order delivery
  could leave `smb.conf` or the UI showing a drive that was already
  gone. The SSE stream now drops the oldest queued update rather than
  the newest.
- **Restarts are quick with the web UI open.** An open event stream no
  longer stalls shutdown for 10 s.
- **ext4 labels are limited to 16 bytes, not 16 characters.** Multi-byte
  labels are also truncated on a UTF-8 boundary.
- **fsck check mode says "errors found".** It used to report "errors
  corrected" for exit code 1.

### Fixed — image, installer, release

- **The pi-gen image is really 64-bit now.** It's built from pi-gen's
  `arm64` branch, pinned to a tag. `master` had been silently building
  armhf.
- **Releases attach the right image.** The job used to pick up stock Pi
  OS Lite by mistake (the image build had failed on 0.3.0 and 0.3.1).
  0.4.0 is the first release meant to ship a flashable
  `airlock-<tag>-linux-arm64.img.xz`.
- **`install.sh` installs its config from the release bundle.** The
  config can no longer drift from the image. Machines set up with the
  installer now advertise `_airlock._tcp`, so the companion finds them.
  The installer also works under `curl | bash` and honours
  `AIRLOCK_PREFIX` in the unit.
- **Documented `AIRLOCK_X=1 curl … | sudo -E bash` one-liners are
  corrected.** They never passed the flag through; the docs now use
  `curl … | sudo AIRLOCK_X=1 bash`.
- **Release workflow:**
  - Jobs no longer race to create the release.
  - Manual runs build the tag, not `main`.
  - `.sha256` files hold bare filenames.
  - The bundle and `install.sh` now get checksums.

### Fixed — macOS companion

- **Auto-mount:**
  - It no longer re-mounts a drive you just unmounted or ejected.
  - It no longer tries offline hosts or starts duplicate mounts.
  - It backs off after failures.
  - It skips drives that are ejecting.
- **Eject:**
  - Eject aborts if the local unmount fails (open files) rather than
    pulling the drive out from under the Mac. The daemon's busy
    message is shown.
  - Eject all waits for every local unmount first.
- **Offline hosts show "offline · last seen …"** instead of a red
  "cancelled".
- **The event stream:**
  - It's thread-safe.
  - It reports HTTP errors properly.
  - It backs off correctly on a flapping server.
- **Mounting never shows an auth dialog.**
- **Mount state is read without blocking the main thread.**
- **The DMG is a universal binary** (arm64 + x86_64).
- **Build fixes:**
  - `swift run` no longer crashes.
  - The XcodeGen project has an entry point again.
- **Clean under Swift 6 strict concurrency.**
- **Notifications:**
  - They show while the app is active.
  - A failed permission request no longer blocks asking again later.
- **Copy SMB URL** percent-encodes the share name.

### Changed

- **Toolchains:**
  - Go 1.22 → 1.27, and `golang.org/x/sys` v0.18 → v0.48.
  - Node 20 → 24 for the docs site.
  - `npm audit fix` in `docs/`.
- **All GitHub Actions bumped to current majors.** Third-party actions
  are pinned to a commit SHA.
- **CI now runs:**
  - `gofmt`, `go vet` and `go test -race`;
  - `shellcheck` on every script;
  - `testparm` on the Samba config.
- **Tests for every daemon package.** They cover symlink escapes on
  every file operation, the cross-origin and Host guards, the op lock,
  system-disk detection, udev parsing, Samba rendering, and
  mkfs/fsck/label commands.
- **Duplicated device/partition lookups, device-name checks and
  filesystem-name mappers merged; dead code removed.**
- **Every API error is a JSON `{"error": …}` body.**
- **Docs:**
  - Stale pages were updated.
  - Broken anchors were fixed.
  - A "Flash the image" section was added.
  - The companion README was rewritten.

### Version surfaces

- **Daemon:** `main.version` is `0.4.0`.
- **Companion:** `CFBundleShortVersionString`, `CFBundleVersion`,
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are `0.4.0`.
- **Installer:** installing an older version with
  `AIRLOCK_VERSION=0.3.x` needs that release's own `install.sh`. Those
  releases publish no bundle checksum, and the new installer refuses
  to install unverified files.

## [0.3.1] — 2026-07-14

Patch release: shipping the companion with a proper app icon so it
stops looking like a generic PkgInfo blank in Finder / Launchpad /
About dialogs.

### Added

- **App icon for the macOS companion.** SVG source at
  `companion/mac/assets/AppIcon.svg` (an airlock-hatch metaphor in
  the site's green gradient), rendered to `AppIcon.icns` via a
  `make-icon.sh` helper (librsvg + `iconutil`). Both files are
  committed so `build.sh` and CI don't need librsvg — regenerate
  locally with `./make-icon.sh` after editing the SVG. Info.plist
  gets `CFBundleIconFile: AppIcon`; the .app bundle picks it up in
  Finder, Launchpad, and (if you unhide the Dock) the Dock. The
  menu-bar icon stays as the `externaldrive.badge.wifi` SF Symbol —
  optimized for 22 pt template rendering.

### Version surfaces

- Daemon `main.version` bumped to `0.3.1`.
- Companion `CFBundleShortVersionString` / `MARKETING_VERSION` bumped
  to `0.3.1`; Preferences window auto-picks it up from Info.plist.
- No API or on-wire change — the daemon bump is only so
  `Version 0.3.1` shows correctly in the web UI footer.

## [0.3.0] — 2026-07-14

Adds a macOS menubar companion app, daemon-side plumbing to push live
drive updates over Server-Sent Events, and a VitePress product site
at [airlock.emdzej.pl](https://airlock.emdzej.pl). No changes to the
existing 0.2.0 REST API — the companion app is a strict additive
layer.

### Added — Mac companion app (`companion/mac/`)

- New menubar-only `AirlockCompanion.app` (Swift Package +
  `LSUIElement`). Discovers airlock instances via the new
  `_airlock._tcp` Bonjour service; lists their drives; per-drive
  actions **Mount** / **Mount and Open in Finder** / **Unmount** /
  **Reveal in Finder** / **Copy SMB URL** / **Eject drive from
  airlock**; per-host **Eject all drives** and **Open web UI**.
- **Silent mount** via `NetFSMountURLSync` from `NetFS.framework` —
  same DiskArbitration path Finder uses, but no window pops on
  mount. `NSWorkspace.open(smb://…)` was the first draft; it worked
  but always opened a window, making "Mount" and "Mount and Open"
  indistinguishable.
- **Auto-unmount reconciliation**: when a drive is ejected on the
  daemon side (web UI, GPIO button, format), the Mac's local SMB
  mount is dropped automatically. Skipped when the host is
  currently offline so a Pi reboot doesn't yank live mounts.
- **Preferences window**: `Auto-mount all discovered drives`,
  `Open in Finder after mounting`, `Start at login` (via
  `SMAppService.mainApp` on macOS 13+), plus a footer with the app
  version + a GitHub link.
- **Persistent host store**: airlocks the app has seen appear in the
  menu even when offline, with `offline · 2h ago`. Prune after 30
  days of not-seen. Restores drive list from cache on launch so the
  menu is populated before the first SSE reconnect finishes.
- **Coloured host status dot**: green live · grey offline · red
  error, with the last error inline.
- **Live updates via SSE** with exponential-backoff reconnect and
  `URLSessionDataDelegate`-based frame parsing (bypasses the
  URLSession.bytes buffering issue on macOS 13/14).
- **XcodeGen `project.yml`** for developers who want Xcode.
  `.xcodeproj` stays gitignored.
- **Distributable DMG** via `package.sh`. The .app inside is
  **ad-hoc signed** (`codesign --force --deep --sign -`) so macOS 15
  Sequoia's stricter Gatekeeper — which no longer honours the old
  right-click Open bypass on unsigned apps — treats it as a normal
  first-run prompt instead of "damaged and can't be opened." Not
  notarized (no Apple Developer Account); users still need one
  `xattr -dr com.apple.quarantine /Applications/AirlockCompanion.app`
  after copying, documented in the companion guide.

### Added — daemon

- **`GET /api/events`** — Server-Sent Events stream broadcasting the
  current drive list on every mount-manager change. Initial snapshot
  on connect, heartbeat comment lines every 30 s, event types are
  wrapped in an envelope (`{"type":"drives","drives":[...]}`) so we
  can add more event kinds without a breaking wire change.
- `mount.Manager.AddListener` so multiple downstream consumers can
  subscribe to drive-change events. The Samba writer and the SSE
  broadcaster both hook in via this now instead of wrapping the
  primary listener.
- Additional `_airlock._tcp` Bonjour advertisement (port 80, TXT
  `api=1 path=/`). Companion apps browse for exactly that instead of
  filtering `_smb._tcp` / `_http._tcp`.

### Added — release workflow

- New `companion-mac` job on `macos-14`. Stamps `Info.plist` with
  the release tag, builds the .app via `swift build`, packages a
  DMG via `hdiutil`, attaches `AirlockCompanion-<tag>.dmg` +
  sha256 to the same GitHub release the daemon binary and pi-gen
  image are already on.

### Added — product site (`docs/`)

- **[airlock.emdzej.pl](https://airlock.emdzej.pl)** — VitePress site
  built from the existing `docs/` folder. New landing hero page, a
  product overview, and a dedicated macOS companion guide sit next
  to the existing user guide and install guide (same source, no
  duplication).
- `.github/workflows/site.yml` builds and publishes to GitHub Pages
  on every push to `main` that touches `docs/**`, using
  `actions/deploy-pages@v4`. Custom domain via `docs/public/CNAME`;
  DNS + Pages source (`GitHub Actions`) configured out-of-band on
  the repo.

### Version surfaces

- Web UI footer already links `Version 0.3.0` → the repo.
- Companion app's Preferences window shows `Airlock Companion 0.3.0`
  at the bottom with a matching GitHub link.
- Daemon `main.version` bumped to `0.3.0`; release workflow
  overrides via `-ldflags -X main.version=<tag>` for tagged builds.

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
  (with per-service explanation, measured impact, and a manual recipe),
  **Additional hardening** (systemd sandbox + optional USB blocklist),
  and **Flashing OS images to a drive**.
- **"Why the name" section** in the README explaining the security
  posture — Airlock as the isolation chamber between untrusted media
  and your primary machine (`nosuid,nodev,noexec`, no autorun, BadUSB
  neutralization on a headless box, kernel FS-parser CVEs land on the
  Pi instead of your laptop). Explicit note that endpoint hygiene
  (AV, sandbox) is still the user's job.
- Devices tab payload now includes `can_mount`, `can_relabel`, and
  `can_fsck` flags per partition, so the UI shows only the actions
  that make sense for each filesystem.

### Fixed

- **Duplicate mDNS advertisement removed.** Samba's built-in mDNS
  publisher was shipping a competing `_device-info._tcp` (and
  `_smb._tcp`) record under the NetBIOS name `AIRLOCK` with
  `model=MacSamba`, which shadowed the record our Avahi service
  publishes. Suppressed via `multicast dns register = no` in
  `smb.conf`. The Avahi service still advertises
  `_device-info._tcp` with `model=MacPro7,1@ECOLOR=226,226,224`; the
  actual icon Finder draws depends on macOS's undocumented icon
  table, and reliably matching a specific "network storage"
  appearance (e.g. TrueNAS's) requires macOS-side vendor recognition
  we can't advertise.
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
