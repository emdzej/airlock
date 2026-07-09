# User guide

This is the day-to-day reference for using Airlock. For first-time
installation see [`install.md`](install.md); for release notes see
[`../CHANGELOG.md`](../CHANGELOG.md).

## Overview

Airlock exposes USB storage (thumb drives, SD-in-USB-reader, external
SSD) plugged into a Raspberry Pi to your local network. The Pi does
the mounting; every client uses either:

- The **web UI** at `http://<host>.local/` — the same set of tools this
  guide covers.
- **SMB** at `smb://<host>.local/<label>` — normal file-manager access
  from macOS Finder, Windows Explorer, Linux Files, etc.

Everything is guest-access by design — the appliance trusts your LAN.
See the **security posture** section below for the honest scope of
what that means.

## Accessing airlock

### From the web UI

Open `http://<host>.local/` in any browser on the same network. If mDNS
is filtered on your network (rare at home, common on corporate Wi-Fi),
use the Pi's IP directly.

The UI has two tabs:

- **Mounts** — what's currently shared. Day-to-day browsing.
- **Devices** — physical devices attached. Everything destructive lives
  here.

### From macOS Finder

⌘K → `smb://<host>.local` → **Connect As: Guest**. Or from the CLI:

```sh
mount_smbfs //guest@<host>.local/<share> /Volumes/<share>
```

Empty password — just press return. If Finder ever asks for credentials,
you selected "Registered User" by mistake; back out and pick Guest.

### From Windows Explorer

Type `\\<host>\<share>` into Explorer's address bar. Modern Windows
disables anonymous / guest SMB by default; if it prompts and no
credential works you need to enable **insecure guest logons**:

```
Group Policy → Computer → Administrative Templates → Network →
Lanman Workstation → "Enable insecure guest logons" → Enabled
```

If you can't change GPO, use the web UI instead — HTTP has no such
lockdown.

### From Linux

Nautilus / Dolphin: sidebar → **Other Locations** → `smb://<host>.local/`.
CLI:

```sh
smbclient -N //<host>.local/<share>
```

## The Mounts tab

Each row is a partition that is currently mounted and shared.

| Element | What it does |
|---|---|
| Drive name (linked) | Click to open the file browser at that share |
| Filesystem · size | Read-only info |
| `smb://host/share` (linked) | Click to open your OS's file manager on that share (works on macOS/Linux/Firefox; Chrome/Edge may prompt or block on Windows) |
| **Copy** button | Copies the platform-appropriate path — `\\host\share` on Windows, `smb://host/share` elsewhere |
| **Eject** | Unmounts every partition of the same physical device (safe to yank after) |
| **Eject all** (top) | Same, but for every mounted drive |

Ejecting drops the SMB share immediately; any client sessions will see
the share disappear and can reconnect once you (re)plug the drive.

## The Devices tab

Every USB-attached block device shows up here, whether mounted or not.
Rows show the vendor / model / serial, size, partition-table type, and
transport (always `USB`).

### Device-level actions

| Button | Effect |
|---|---|
| **Eject** | Unmount every mounted partition of this device |
| **Format…** | Wipe partition table, create a fresh single-partition FS |
| **Flash…** | Overwrite the whole device with an image (`.img` / `.img.xz` / `.img.gz`) |
| **Dump…** | Download the whole device as a disk image, compressed on the fly |

### Partition rows (nested under each device)

Every partition — mounted or not — appears as a nested row with its
kernel name (`sdb1`), filesystem, size, and label. Depending on state,
per-partition actions appear:

| Button | Appears when | Effect |
|---|---|---|
| **Mount** | Partition has a supported FS but isn't currently mounted by airlock | Triggers a mount so the partition becomes a share |
| **Rename** | FS is FAT / exFAT / NTFS / ext2/3/4 and drive is writable | Change the volume label |
| **Check** | FS has a fsck tool we know | Run a filesystem consistency check |

Partitions with unsupported filesystems (UFS, HFS+ RW, LUKS, etc.) show
up with their metadata but no per-partition actions.

## File browser

Open a share by clicking its name in the Mounts tab, or by navigating
to `http://<host>.local/drives/<share>/`.

### Navigating

- **Breadcrumbs** at the top for the current path.
- **Directories** are listed first, then files, both alphabetical.
- Click a directory name to descend, breadcrumbs to jump up, or the
  browser's Back button.

### Downloading

Click any file to download it. Each row also has a **Download** button
(same effect). Big files stream — no client-side buffer.

### Uploading

The toolbar has:

- **Upload files** — pick individual files
- **Upload folder** — pick a whole folder (Chrome / Firefox / Edge /
  Safari all support this)
- **Drag-and-drop** — either files or folders anywhere on the file
  list. Folders are walked recursively; the directory tree on the
  drive matches what you dropped.

Uploads run **one request per file** so a hiccup on one file doesn't
abort the batch. The bottom-right progress card has:

- Aggregate progress bar and current-file counter (`Uploading 3 of 12`)
- A **Details** toggle showing every file with its own progress:
  `○ queued`, `↑ 45 %` (in flight), `✓ done`, `✗ error`
- Auto-opens on the first failure so you see what broke; auto-hides
  after successful completion.

### Rename / delete / new folder

- **Rename** on any row: modal with a text input. Applies immediately.
- **Delete** on any row: `confirm()` dialog first (file or whole folder).
- **New folder** in the toolbar: modal with a name input; created at
  the current path.

Read-only drives (write-protect switch, iso9660, hybrid ISOs) hide the
upload / rename / delete / mkdir actions and show a banner at the top
of the browser explaining why.

## Formatting a drive

**Destructive — erases every partition on the target device.**

Devices tab → **Format…**. The modal shows:

- The target device and its total size
- Every partition on the device with its label + FS + size (so you know
  exactly what disappears)
- Filesystem picker: FAT32, exFAT, NTFS, or ext4 — auto-selected by
  size (FAT32 <32 GB, exFAT ≥32 GB)
- New volume label (optional)
- **Type-to-confirm** — must type the drive's current label, or the
  word `FORMAT` if the drive is unlabeled

Progress is streamed live from the daemon:

```
unmount → wipe → partition → rescan → mkfs → done
```

When done the modal closes; the fresh partition shows up as a new
share on the Mounts tab within a couple of seconds.

**Safety guards:**

- Only USB-attached devices can be targeted — the Pi's own boot SD
  can never appear here.
- Refused if any partition is currently marked read-only (write-protect
  switch tripped, etc.).
- During the format the daemon quarantines the target, so a race where
  it tries to auto-mount the fresh partition mid-`mkfs` can't happen.

## Renaming a volume

Devices tab → per-partition **Rename**. Modal has a text input with
the correct max length for the filesystem (11 for FAT32, 15 for
exFAT, 32 for NTFS, 16 for ext*).

Under the hood: the partition is unmounted, `fatlabel` / `exfatlabel` /
`ntfslabel` / `e2label` runs, then udev re-fires so the daemon
re-mounts under the new label. SMB clients need to reconnect using
the new share name.

## Mounting an unmounted partition

Devices tab → per-partition **Mount**. Fires `udevadm trigger --action=add`
for that partition; the daemon's normal event handler picks it up.

Useful when:

- You ejected a partition earlier and want it back without unplugging.
- A hybrid layout means one partition was skipped (e.g. the ISO
  parent claimed the whole disk).
- You just formatted and the automatic re-mount didn't fire for some
  reason.

## Running fsck

Devices tab → per-partition **Check**. Modal offers:

- **Check only** — read-only pass, no changes (`-n` for e2fsck /
  fsck.vfat / fsck.exfat; `--no-action` for ntfsfix)
- **Repair** — safe auto-fix (`-p` preen for e2fsck; `-a` for
  fsck.vfat; `-y` for fsck.exfat / ntfsfix)

The panel below shows the tool's stdout / stderr live as it runs. Exit
codes are interpreted:

| Code | Meaning |
|---|---|
| 0 | Clean |
| 1–2 | Errors corrected |
| 4 | Errors remain — try Repair mode |
| ≥8 | Tool failure |

Caveats per filesystem:

- **NTFS**: `ntfsfix` is not a full `chkdsk` — it fixes only a few
  common issues. For deep repair, run `chkdsk` from Windows.
- **HFS+**: `fsck.hfsplus` is check-only in Airlock — no repair mode.
- **exFAT**: modern `fsck.exfat` (from `exfatprogs`) supports both
  check and repair. Older versions may not.

## Backing up: dump a device to an image

Devices tab → **Dump…**. Choose compression:

- **xz** (default) — best ratio, fully-empty regions compress massively.
  A 32 GB SD with 500 MB of data typically produces a 100–200 MB `.img.xz`.
  Multi-threaded (`-T 0`) so all cores help.
- **gzip** — faster, decent ratio.
- **none** — raw `.img`. Fastest, biggest file.

The browser starts a normal download. Filename is auto-generated from
the partition label + date:

```
airlock-<label>-<yyyy-mm-dd>.img[.xz|.gz]
```

**Read-only operation** — Airlock calls `sync()` before opening
`/dev/<parent>` for read but does *not* unmount. SMB clients keep
their sessions.

For a **bit-perfect** dump (e.g. forensics or a card you plan to
restore via `dd`), eject the drive first, then dump, then plug back
in. Otherwise fs-buffered writes in flight during the dump could
produce a slightly-inconsistent snapshot.

## Flashing an OS image to a drive

**Destructive — overwrites the whole device.**

Devices tab → **Flash…**. Pick an image file:

- `.img` — raw, no decompression
- `.img.xz` — decompressed on the Pi via `xz -dc`
- `.img.gz` — decompressed via stdlib gzip
- `.zip` — not supported yet; extract locally first

Airlock detects compression from the filename. The dialog shows the
target device, the picked file, its size, and a warning if a raw image
is bigger than the target.

Type the confirmation word (drive label, or `FLASH` for unlabeled
media) to enable the **Flash** button.

### What happens during flash

1. Upload streams over HTTP from browser → server
2. Server pipes: `request body → xz -dc / gzip.Reader / passthrough → /dev/<parent>` in 4 MB chunks
3. Progress bar tracks the higher of (upload %, bytes written / device size)
4. Once the write finishes: `sync`, `partprobe`, `udevadm trigger`
5. The daemon picks up any new partitions and remounts them as shares

Zero intermediate storage — a 3 GB Pi OS image never lands on the Pi's
boot SD, only on the target USB drive.

### Progress display

Two counters appear during flash:

- **uploaded** — bytes the browser has sent (still compressed for `.xz`)
- **written** — bytes actually landed on the target device (raw, post-decompress)

For `.img.xz` uploads, the "written" number will typically be 3–5× the
"uploaded" one because Pi OS images decompress massively. This is
normal.

### Safety guards

- Only USB devices can be targeted (never the Pi's own SD)
- Refused if any partition on the device is read-only
- Refused if the raw (uncompressed) upload is bigger than the target
- Device is quarantined during the flash so partial partition tables
  don't fire race-conditions on the daemon

## Physical eject button + LED (optional)

If you wired the reference hardware from the install guide:

- **Button** on GPIO 17 (physical pin 11): pressing it triggers
  **Eject all** — every mounted drive is unmounted.
- **LED** on GPIO 27 (physical pin 13):

| LED state | Meaning |
|---|---|
| off | No drives mounted — safe to yank anything |
| solid | Drives mounted, nothing busy — safe to press the button |
| fast blink (~4 Hz) | Eject / format / flash / dump in progress — do NOT yank |

The daemon runs fine without any GPIO wiring. If the button and LED
aren't connected, the physical eject path just doesn't exist; the
web UI's eject still works.

## Security posture

The whole point of the appliance is to isolate untrusted USB media
from your primary machine. In practice:

- Every mount uses `nosuid,nodev,noexec` — no binary on the drive can
  execute, gain privileges, or open a device node on the Pi. And it
  never runs on your laptop directly.
- Airlock never auto-runs anything from the media.
- **BadUSB / USB Rubber Ducky** devices (a stick that pretends to be a
  keyboard) plug into a headless Pi with no interactive session to
  type into. On your laptop the same device would type into whatever
  window has focus.
- Kernel filesystem-parser CVEs (rare but real for FAT / NTFS / exFAT /
  HFS+) land on the Pi, not on the trusted machine.

You still have to be careful about **file content**. A booby-trapped
PDF or macro-laden Office document is Airlock's cargo, not its concern.
Endpoint hygiene (AV, Gatekeeper on macOS, SmartScreen on Windows,
whatever's on your machine) still matters.

For the two optional tightening layers — USB device-class blocklist
and read-only root — see [`install.md`](install.md) under
**Additional hardening**.

## Troubleshooting

### `airlock.local` doesn't resolve

Confirm Avahi is running: `systemctl status avahi-daemon` on the Pi.
If your network filters mDNS (some corporate Wi-Fi does), use the
IP directly: `http://192.168.x.y/`. The IP shows up in the daemon's
startup log — `journalctl -u airlockd | grep listening`.

### Web UI works but SMB shows no shares

- Check `sudo testparm -s` on the Pi for Samba syntax errors.
- Confirm `smbd` is running: `systemctl status smbd`.
- On Windows, the "insecure guest logons" GPO must be enabled
  (Microsoft KB4046019 — this is a Windows client-side setting, not
  something Airlock controls).
- On macOS, make sure you selected **Connect As Guest**, not
  Registered User.

### USB drive not appearing after plug-in

- Verify with `lsblk` on the Pi that the kernel sees it.
- If it's a whole-disk filesystem or has partitions we don't
  auto-mount (UFS, LUKS, etc.), it will still show up on the
  **Devices** tab — just with no per-partition actions. Format
  or Flash still work at the device level.
- If it's a native SD in the Pi's built-in slot, we intentionally
  don't touch it — that's the boot media.

### Flash or format hangs

- Client-side hangs are usually the browser timing out. Check the
  daemon log: `journalctl -u airlockd -f`.
- If the device gets physically unplugged mid-flash you'll see
  `input/output error` from the kernel. The daemon lifts the
  quarantine and reports "flash failed". Re-plug and retry.
- xz decompression can take a while after the upload finishes —
  the progress bar stays at 100 % for the upload phase while the
  server drains its buffer. That's expected.

### Where to look for logs

```sh
journalctl -u airlockd -f            # daemon
journalctl -u smbd -f                # Samba
journalctl -u avahi-daemon -f        # mDNS / discovery
```

For faster boot / less-noisy log volume, see [`install.md`](install.md)
under **Optional: faster boot**.
