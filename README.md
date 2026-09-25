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

## Why the name

Borrowed from spacecraft and cleanrooms: an *airlock* is the intermediate
compartment that isolates two environments while goods pass between them.
That's exactly the security posture here.

- The **untrusted USB media** — someone else's thumb drive, a card of
  unknown provenance, a booby-trapped stick — plugs into the Pi. Not
  into your primary machine.
- Every mount uses `nosuid,nodev,noexec`; nothing on the drive can execute,
  gain privileges, or open a device node on the Pi.
- Airlock never auto-runs anything from the media. Linux has no
  `autorun.inf`; we don't scan-and-execute anything either.
- **BadUSB / USB Rubber Ducky** attacks (a drive that pretends to be a
  keyboard) land on a headless Pi with no interactive session to type
  into — not on your laptop where they'd do damage. Optional
  `AIRLOCK_HARDEN_USB=1` refuses HID and CDC-* USB drivers entirely.
- Kernel filesystem-parser CVEs (rare but real for FAT / NTFS / exFAT /
  HFS+) are hitting a $50 Pi you can reflash, not the machine you
  actually work on.

You still have to be careful with **file content** — a booby-trapped PDF
or macro-laden Excel document is Airlock's cargo, not its concern. Endpoint
hygiene (AV, sandbox, Gatekeeper, whatever's on your side) still matters.
Airlock is the isolation chamber; it's not a scanner. See [`docs/install.md`](docs/install.md)
under **Additional hardening** for the full posture and the two optional
tightening levels.

## Status

Version **0.4.0** — daemon plus a macOS menubar companion app.
Runs on real hardware (Raspberry Pi 4 on Debian 13 / Trixie).
Mounts, file management, format, flash, dump, fsck, volume relabel,
opt-in USB / boot / Wi-Fi hardening, and now a live-updating menu-bar
client with silent mount, auto-mount, and auto-unmount-on-eject.
See [`CHANGELOG.md`](CHANGELOG.md) for what's in the release.

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

**Fresh SD card** — from 0.4.0 every release ships a flashable image,
`airlock-<version>-linux-arm64.img.xz`. Flash it with Raspberry Pi Imager
and use its OS customisation to set your SSH public key (password SSH is
off by default) and Wi-Fi. See [Flash the image](docs/install.md#flash-the-image).

**On an existing Raspberry Pi** (Bookworm or Trixie, 64-bit) — one line:

    curl -fsSL https://github.com/emdzej/airlock/releases/latest/download/install.sh | sudo bash

Options go after `sudo` (it resets the environment), e.g.
`… | sudo AIRLOCK_HARDEN_USB=1 bash`.

Once done: open `http://<hostname>.local/` in a browser, or connect via
`smb://<hostname>.local/` from Finder / Explorer / Files.

See the [**user guide**](docs/guide.md) for day-to-day usage of every
feature (Mounts / Devices tabs, file browser, format, flash, dump, fsck,
volume relabel), and the [**install guide**](docs/install.md) for setup,
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
- `scripts/install.sh` — installer for an existing Raspberry Pi (installs the config files from `image/pi-gen/stage-airlock` via the release bundle)
- `.github/workflows/` — CI (build/test/lint), Release (tag → binaries, bundle, image, DMG) and the docs site
- `CHANGELOG.md` — release notes
- `docs/` — [user guide](docs/guide.md), [install guide](docs/install.md), [backlog](docs/backlog.md)

## Build

    make airlockd            # host binary (for editor/CI use — daemon is Linux-only)
    make airlockd-arm64      # cross-compile for Pi 4
    make image               # build the full pi-gen image (Linux + docker)
    make test                # go test -race
    make lint                # gofmt check + go vet + shellcheck

## Support

If you find this project useful, consider [buying me a coffee](https://buymeacoffee.com/emdzej) ☕ or [sponsoring on GitHub](https://github.com/sponsors/emdzej) or if it's your thing: via PayPal

[![Donate with PayPal](https://www.paypalobjects.com/en_US/PL/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/donate/?business=TDBR3A97PLQRQ&no_recurring=0&item_name=%28emdzej%29&currency_code=PLN)

## License

[MIT](LICENSE).
