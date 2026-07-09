# Milestones

## M0 — De-risk the OS integration ✅

Prove the four things that could surprise us before writing polished code.

- [x] pi-gen custom stage producing an arm64 Bookworm image with read-only root
  (`image/pi-gen/`)
- [x] udev rule tagging USB/mmc block devices; airlockd subscribes to
  `NETLINK_KOBJECT_UEVENT` group 2 and delivers typed events
  (`image/pi-gen/stage-airlock/04-udev/`, `internal/mount/udev*.go`)
- [x] Multi-partition detection + mount to `/mnt/airlock/<name>` with fs-specific
  options (`internal/mount/manager.go`)
- [x] Samba dynamic share via a single include file + `smbcontrol reload-config`
  (`internal/samba/`, `image/pi-gen/stage-airlock/02-samba/`)

**Next validation step:** build the image on a Linux host with docker, flash to
a Pi 4, plug in a labelled USB stick, verify:

1. `airlock.local` resolves and pings
2. `smbclient -L //airlock.local -N` lists the drive as a share
3. Yanking the drive removes the share from the list
4. `journalctl -u airlockd` shows sensible add/remove events

## M1 — Minimum working appliance ✅ (code complete, needs hardware test)

- [x] HTTP status page (`internal/api/`) listing mounted drives + eject buttons
- [x] GPIO 17 button → global eject; GPIO 27 LED state machine
  (off / solid / fast-blink busy). Slow-blink dirty deferred to M2 when we
  have upload/write traffic to base it on.
- [x] `orchestrator` in `cmd/airlockd/main.go` reconciles LED state from
  drive count + busy reference count.
- [x] Sync-on-shutdown (no auto-unmount — appliance ethos).
- [ ] Avahi advertising confirmed working (image config in place — needs Pi).
- [ ] First flashable image tag (needs a full pi-gen build run on Linux+Docker).

**Hardware verification checklist (needs a Pi 4 + one USB drive + wired button/LED):**

1. `curl http://airlock.local/` — status page loads, empty state visible
2. Plug in a USB drive → within 3s the page shows the drive and its share path
3. `smbclient -N -L //airlock.local` lists the same share
4. Press the GPIO 17 button → LED blinks fast, drive disappears from page
5. Plug drive back in → mounts under same name, LED goes solid
6. `journalctl -u airlockd` reveals no error spam

Known limitation to verify on Pi 5: `ChipName` defaults to `gpiochip0` (Pi 4).
Pi 5 uses `gpiochip4` — override via config once we thread env-based config
through the daemon.

### Hardware findings (Trixie / kernel 6.18 / Pi 4)

- End-to-end mount → Samba dynamic share → guest SMB browse from macOS works.
- **Critical bug found & fixed:** the previous udev rule also matched native
  `mmcblk*` devices; combined with `udevadm trigger` on daemon startup this
  briefly exposed `/boot/firmware` and `/` over SMB. Fixed by (a) restricting
  the udev rule to `sd*` + `ID_BUS=usb` and (b) skipping any device that is
  already mounted anywhere in `/proc/self/mountinfo`.
- Hybrid ISO layout (Proxmox VE installer): whole-disk `sda` mounts as
  iso9660; partitions `sda2` (vfat) / `sda3` (hfsplus) correctly skipped now.
- Owner lookup: works on both a pi-gen image (`airlock`) and this dev Pi
  (`emdzej`). No hardcoded username assumption.
- Startup state recovery: on restart, `mgr.Recover()` force-unmounts any
  leftover `/mnt/airlock/*` mounts, then `mgr.ReplayUdev()` triggers ADD
  events for currently attached devices.

## M2 — Full file management ✅

- [x] `internal/fsops/` — safe path resolution (`..` escape, NUL, symlink
  containment via `EvalSymlinks` re-check for reads), List/Open/Create/
  Remove/Rename/Mkdir. Unit-tested (7 tests).
- [x] JSON API: `GET ls`, `GET dl` (streaming, `http.ServeContent` for Range
  support), `POST upload` (multipart streamed via `MultipartReader`),
  `DELETE rm`, `POST mv`, `POST mkdir`. Read-only drives → 403 on writes.
- [x] File browser UI at `/drives/{share}/`: breadcrumbs, dir click-through,
  download links, drag-and-drop upload with `XMLHttpRequest` progress,
  inline rename via `<dialog>`, confirm-delete, mkdir.
- [x] End-to-end verified on Pi (Debian Trixie) against a real vfat drive —
  mkdir, upload, ls, download, rename, delete all round-trip. Path
  traversal correctly rejected (400).

### M2 punch list (nice-to-have follow-ups)

- Multi-file upload progress: currently shows aggregate percent but no
  per-file breakdown. Fine for MVP.
- Text/image preview in the browser instead of forced download. Would
  need Content-Disposition switch on file extension.
- Sorting toggle (name / size / date). Right now: dirs first, name asc.
- Selection + bulk actions (delete many, download as zip). Backlog.

## M3 — Format ✅ (code complete; awaiting hardware verification with an expendable drive)

- [x] `internal/format/` package: unmount → wipefs → parted mklabel msdos +
  mkpart → partprobe → mkfs.{vfat,exfat,ntfs,ext4} → udevadm trigger.
- [x] `POST /api/devices/{parent}/format` responds with `text/event-stream`,
  one `data: {"stage":"...","message":"..."}` per stage. Runs on a
  background context so client disconnects don't corrupt a mid-format drive.
- [x] `GET /api/devices/{parent}` returns whole-disk size, list of every
  share on the device, suggested filesystem (FAT32 <32 GB else exFAT), and
  a `read_only` flag that gates the UI's Format button.
- [x] UI: "Format…" button in the browse toolbar → modal shows physical
  size + every share that will disappear + FS picker (radios) + label
  input + type-to-confirm (matches the current volume label, or "FORMAT"
  if unlabeled).
- [x] Reads whole-disk size from `/sys/class/block/{parent}/size` via new
  exported `mount.DeviceSize` — earlier drafts wrongly showed the mounted
  partition's size in the modal.
- [ ] End-to-end format with `vfat` / `exfat` / `ntfs` / `ext4` — needs an
  expendable USB drive on the Pi.

### Design notes

- Always MBR partition table for now (universal camera / consumer-device
  compatibility, works up to 2 TB). GPT switch for larger drives when we
  actually see >2 TB media plugged in.
- Whole-disk single partition. No partition editor. Users who need
  multi-partition layouts have `fdisk` and `parted` for that.
- Format re-triggers via `udevadm trigger --action=change` on the new
  partition so blkid re-probes the fresh filesystem and the mount manager
  picks it up automatically.

## M4 — Polish & docs

- Wi-Fi provisioning via Pi Imager's `firstrun.sh`
- Reflash-preserving-settings (Wi-Fi creds and hostname on the boot partition)
- Hardware guide (case recs, PoE HAT, GPIO wiring diagram)

## Post-M4

See [backlog.md](./backlog.md).
