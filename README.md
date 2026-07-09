# Airlock

A **network card reader appliance** for the Raspberry Pi 4.

Plug a USB thumb drive, SD card, or external SSD into the Pi. It appears on
your home network within seconds — accessible over SMB (Finder, Explorer,
Files, `smbclient`) and a small web UI in the browser.

Built for the person whose laptop has USB locked by corporate policy, or who
just wants a tidy way to move files off a card without hunting for a reader.

    [your laptop]  ←—  Wi-Fi / Ethernet  —→  [Pi 4 with drive plugged in]
                       smb://airlock              airlock.local
                       http://airlock/

## Status

Version **0.2.0** — first tag. Runs on real hardware (Raspberry Pi 4 on
Debian 13 / Trixie). Mounts, file management, format, volume relabel,
opt-in USB / boot / Wi-Fi hardening all work; the flashable pi-gen image
still needs a full build round-trip. See [`CHANGELOG.md`](CHANGELOG.md)
for what's in the release and [`docs/milestones.md`](docs/milestones.md)
for how we got here.

## Design

| | |
|---|---|
| Target hardware | Raspberry Pi 4 (2 GB+), Ethernet or Wi-Fi, PoE HAT recommended |
| Discovery | mDNS (`airlock.local`) via Avahi. Home / small-office LAN. |
| Sharing | SMB (Samba, guest access) + HTTP UI on port 80 |
| Filesystems | FAT32, exFAT, NTFS, ext4 read-write; HFS+ read-only |
| Auth | None. Trusts the LAN. |
| OS image | Custom [`pi-gen`](image/pi-gen/) stage, read-only root, tmpfs logs |
| Eject | Physical GPIO button + status LED, mirrored in the web UI |

Not designed for enterprise / managed / DLP-controlled networks. See the
[user guide](docs/guide.md) for the honest security posture.

## Quick start

**On an existing Raspberry Pi** (Bookworm or Trixie, 64-bit) — one line:

    curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash

Once done: open `http://<hostname>.local/` in a browser, or connect via
`smb://<hostname>.local/` from Finder / Explorer / Files.

See the [**install guide**](docs/install.md) for a detailed manual walkthrough,
GPIO wiring, uninstall, and troubleshooting.

**Building from source (for a fresh image, or to iterate on the daemon):**

    make airlockd-arm64      # cross-compile the daemon
    make image               # build the full pi-gen image (Linux + docker)

## Repo layout

- `cmd/airlockd/` — main daemon (Go)
- `internal/mount/` — udev events, mount / unmount, RO detection
- `internal/samba/` — dynamic `smb.conf` include + reload
- `internal/gpio/` — button + LED via `/dev/gpiochip0`
- `internal/api/` — HTTP server + embedded status page
- `image/pi-gen/` — custom pi-gen stage (`stage-airlock/`)
- `scripts/install.sh` — installer for an existing Raspberry Pi
- `.github/workflows/` — CI (build/test) and Release (tag → binaries)
- `CHANGELOG.md` — release notes
- `docs/` — [install guide](docs/install.md), [milestones](docs/milestones.md),
  [backlog](docs/backlog.md)

## Build

    make airlockd            # host binary (for editor/CI use — daemon is Linux-only)
    make airlockd-arm64      # cross-compile for Pi 4
    make image               # build the full pi-gen image (Linux + docker)

## License

TBD.
