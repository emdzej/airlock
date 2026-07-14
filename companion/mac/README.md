# Airlock Companion for macOS

A small menu-bar app that discovers airlock instances on your local
network (via `_airlock._tcp` Bonjour) and shows their drives in your
menu bar. Sits alongside the web UI — the web UI does the heavy stuff
(browse, format, flash, dump); the companion is for at-a-glance status
and one-click actions.

**Status:** early scaffold — currently *only* discovers hosts and lists
drives read-only. Eject / mount / auto-mount actions land in the next
iteration.

## Requirements

- macOS 13 (Ventura) or later
- Xcode command-line tools (`xcode-select --install`)
- Swift 5.9+ (bundled with Xcode command-line tools)

## Build & run

```sh
cd companion/mac
./build.sh
open build/AirlockCompanion.app
```

The status-bar icon (an SF Symbol of an external drive with a Wi-Fi
badge) appears in the top-right menu bar. Click it to see discovered
airlock hosts and their drives. Right-click → **Quit** to exit.

For development iteration without repackaging the .app bundle:

```sh
swift run
```

That skips the bundle wrap — the app runs in the foreground with a
Dock icon (because `LSUIElement=YES` isn't applied without the
bundle). Fine for development; use `./build.sh` for anything you'd
actually keep in your menu bar.

## What it does today

- Browses `_airlock._tcp.local.` via `NetServiceBrowser` and resolves
  each match to a hostname + port.
- Polls `GET /api/drives` on each discovered host every 3 s to keep
  the drive list current.
- Renders a menu grouped by host: header with drive count, followed by
  each drive's display name, filesystem, and size.

## What's coming

- **Mount / Unmount** a share on this Mac (`mount_smbfs` + Finder-friendly
  `/Volumes/<share>-on-<host>` naming to avoid collisions across multiple
  airlocks)
- **Eject** — per-drive and per-host, hitting the daemon's existing
  `/api/drives/{share}/eject` and `/api/devices/{parent}/eject`
- **Auto-mount toggle** — a Preferences switch that, when on, mounts
  every new share as it appears
- **Notifications** — plug/unplug/errors as `UNUserNotification` toasts
- **Reveal in Finder** for currently-mounted shares
- **"Open web UI"** menu items per host

See the parent repo's `docs/backlog.md` for the broader roadmap.

## Distribution

Not yet — first cut of this app is meant to be built from source. When
we do release binaries they'll ship as an unsigned `.app` in a DMG on
the main airlock GitHub Releases. Signing / notarization requires an
Apple Developer account; TBD.
