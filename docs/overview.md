# What is Airlock?

Airlock turns a Raspberry Pi 4 into a **network card reader appliance**.
Plug any USB thumb drive, SD card, or external SSD into the Pi, and it
appears on your local network within seconds — accessible over SMB
(Finder, Explorer, Files, `smbclient`) and a small web UI in the
browser.

```
    [your laptop]  ←—  Wi-Fi / Ethernet  —→  [Pi 4 with drive plugged in]
                       smb://airlock              airlock.local
                       http://airlock/
```

Built for the person whose laptop has USB locked by corporate policy,
or who just wants a tidy way to move files off a card without hunting
for a reader.

## Why the name

Borrowed from spacecraft and cleanrooms: an *airlock* is the
intermediate compartment that isolates two environments while goods
pass between them. That's the security posture here.

- **Untrusted USB media** — a friend's thumb drive, a card of unknown
  provenance, a booby-trapped stick — plugs into the Pi. Not into
  your primary machine.
- Every mount uses `nosuid,nodev,noexec`; nothing on the drive can
  execute, gain privileges, or open a device node on the Pi.
- Airlock never auto-runs anything from the media. Linux has no
  `autorun.inf`; we don't scan-and-execute anything either.
- **BadUSB / USB Rubber Ducky** attacks (a drive that pretends to be a
  keyboard) land on a headless Pi with no interactive session to type
  into — not on your laptop where they'd do damage. Optional
  `AIRLOCK_HARDEN_USB=1` refuses HID and CDC-* USB drivers entirely.
- Kernel filesystem-parser CVEs (rare but real for FAT / NTFS /
  exFAT / HFS+) are hitting a $50 Pi you can reflash, not the machine
  you actually work on.

You still have to be careful with **file content** — a booby-trapped
PDF or a macro-laden Excel document is Airlock's cargo, not its
concern. Endpoint hygiene (AV, sandbox, Gatekeeper, whatever you have
on the receiving side) still matters. Airlock is the isolation
chamber; it's not a scanner. See the
[install guide](/install#additional-hardening) for the full posture
and the two optional tightening levels.

## What's in the box

| | |
|---|---|
| **Target hardware** | Raspberry Pi 4 (2 GB+), Ethernet or Wi-Fi, PoE HAT recommended |
| **Discovery** | mDNS (`airlock.local`) via Avahi — home / small-office LAN |
| **Sharing** | SMB (Samba, guest access) + HTTP UI on port 80 |
| **Filesystems** | FAT32, exFAT, NTFS, ext4 read-write; HFS+ read-only |
| **Auth** | None. Trusts the LAN. |
| **OS image** | Custom [`pi-gen`](https://github.com/emdzej/airlock/tree/main/image/pi-gen) stage, read-only root, tmpfs logs |
| **Eject** | Physical GPIO button + status LED, mirrored in the web UI |

Not designed for enterprise / managed / DLP-controlled networks. See
the [user guide](/guide) for the honest security posture.

## Clients

Airlock is a headless appliance — you use it through:

- **Any SMB client** — Finder, Explorer, GNOME Files, `smbclient`.
  Guest access, no password. Best for quick file transfers.
- **The built-in web UI** — open `http://airlock/` in a browser.
  Adds format, flash, dump, fsck, relabel, and a live per-drive file
  browser. Best when you need to *do* something to the media, not
  just copy files off it.
- **The [macOS menu-bar companion](/companion)** — a small
  `AirlockCompanion.app` that auto-discovers airlock instances,
  mounts and unmounts drives silently, and pushes live updates via
  Server-Sent Events. Best if you use one primarily.

## Architecture at a glance

```
              ┌─────────────────────── Raspberry Pi 4 ──────────────────────┐
              │                                                             │
   USB / SD ──┼─▶ udev ─▶ airlockd (Go) ─┬─▶ Samba dynamic include (SMB)   │
              │           │              ├─▶ HTTP + SSE on :80 (Web UI +    │
              │           │              │    /api/events for companions)   │
              │           │              └─▶ GPIO button + LED status       │
              │           │                                                 │
              │       /run/airlock/*     mount state, dynamic smb.conf      │
              │                                                             │
   Bonjour ◀──┼── avahi-daemon advertises _smb._tcp + _airlock._tcp         │
              │                                                             │
              └─────────────────────────────────────────────────────────────┘
```

The Go daemon is the only moving part on top of Debian Trixie plus
Samba and Avahi. Everything else is standard OS.

## Where to go next

- [**Install on a Pi**](/install) — one-line installer for existing
  Raspberry Pi OS Lite systems, or build the full pi-gen image.
- [**User guide**](/guide) — day-to-day usage: browse, format, flash,
  dump, fsck, relabel, GPIO button.
- [**macOS companion app**](/companion) — install the menu-bar
  client, understand Auto-mount and Auto-unmount reconciliation.
- [**Changelog**](https://github.com/emdzej/airlock/blob/main/CHANGELOG.md) —
  release notes from `0.1.0` through the current release.
