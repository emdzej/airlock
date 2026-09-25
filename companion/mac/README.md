# Airlock Companion for macOS

A small menu-bar app that discovers airlock instances on your local
network (via `_airlock._tcp` Bonjour), shows their drives in your menu
bar, and mounts / ejects them in one click. Sits alongside the web UI —
the web UI does the heavy stuff (browse, format, flash, dump); the
companion is for at-a-glance status and everyday actions.

## Install

Download `AirlockCompanion-<version>.dmg` from the main airlock
[GitHub Releases](https://github.com/emdzej/airlock/releases) and drag
the app to `/Applications`. The app is ad-hoc signed but not notarized
(that needs an Apple Developer account), so on first launch macOS may
call it "damaged"; clear the download quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/AirlockCompanion.app
```

The DMG is a universal binary (Apple silicon + Intel), macOS 13+.

## What it does

- **Discovery** — browses `_airlock._tcp.local.` with `NetServiceBrowser`
  and resolves each service to a hostname + port. Hosts seen before are
  remembered (for 30 days) and shown as "offline · last seen …" until
  they reappear.
- **Live drive list** — one Server-Sent Events stream per host on
  `GET /api/events` (`type: "drives"` snapshots). No polling; reconnects
  with exponential backoff (1 s → 30 s) when the stream drops.
- **Mount / Unmount on this Mac** — silent guest SMB mount via
  `NetFSMountURLSync` (no Finder window, no auth dialog). macOS picks the
  mount point (`/Volumes/<share>`, or `/Volumes/<share>-1` on a name
  collision). Mount state comes from the kernel mount table.
- **Eject** — per drive (`POST /api/drives/{share}/eject`) and per host
  (`POST /api/eject-all`). Local mounts are unmounted first; if that fails
  (files open) the eject is aborted and you get a notification. Errors
  from the daemon (e.g. 409 "busy") are shown as-is.
- **Auto-unmount** — when a drive disappears from a reachable host's
  snapshot (ejected from the web UI, physical button, format) or is
  marked `ejecting`, the now-stale local mount is dropped.
- **Auto-mount** (Preferences, off by default) — mounts every drive on
  every reachable host. Drives you unmount yourself (menu, Finder eject)
  stay unmounted until they're unplugged and come back. Failures back off
  quietly after the first notification.
- **Open in Finder after mounting** (Preferences), **Mount and Open**,
  **Reveal in Finder**, **Copy SMB URL**, **Open web UI**.
- **Start at login** via `SMAppService`.
- **Notifications** for mounts, ejects and errors (`UserNotifications`).

## Build & run

Requires macOS 13+, Swift 5.9+. `./build.sh` produces a universal
binary, which goes through XCBuild and needs a full Xcode install; with
only the command-line tools (or for a faster build), pick one arch.

```sh
cd companion/mac
./build.sh                   # universal .app → build/AirlockCompanion.app
ARCHS=arm64 ./build.sh       # single-arch build
./package.sh                 # wraps build/AirlockCompanion.app into a DMG
open build/AirlockCompanion.app
```

`build.sh` ad-hoc signs the bundle; `package.sh` names the DMG after
`CFBundleShortVersionString` in `Info.plist` (the release workflow
stamps the tag there) and fails if it can't read it.

For quick iteration without the bundle:

```sh
swift run
```

The app still stays out of the Dock (it sets the `.accessory` activation
policy at runtime), but without a bundle there's no bundle identifier,
so notifications are logged to stderr instead of shown.

For developers who want Xcode (debugger, etc.):

```sh
brew install xcodegen
xcodegen                     # generates AirlockCompanion.xcodeproj (gitignored)
open AirlockCompanion.xcodeproj
```

The Xcode target uses the committed `Info.plist` unchanged. The SwiftPM
path is what CI uses.

`make-icon.sh` regenerates `assets/AppIcon.icns` from `AppIcon.svg`
(needs `brew install librsvg`); commit both together.
