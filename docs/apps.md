# Apps for Mac, iPhone and iPad

Airlock's native apps find every Airlock on your network by themselves
and do everything the [web UI](/guide#from-the-web-ui) does: browse
and eject drives, format, flash and back up whole devices, check
filesystems and rename volumes. The Mac and iOS apps share the same
screens.

<div class="airlock-shot airlock-shot--mac">
  <img src="/screenshots/mac.webp" alt="Airlock on macOS: an airlock with two shared drives and two card-reader slots" />
</div>

## macOS

A menu-bar app for macOS 14 or later. The menu mounts drives on your
Mac silently, with no Finder window, and can mount every drive as it
appears. **Open Airlock…** in the menu opens the full window.

- **Drives and devices:** live drive list, eject one drive or all of
  them, device details with partitions.
- **Device tools in the toolbar:** Format, Flash Image, Save Image and
  Eject, the way Disk Utility does it.
- **Partitions:** mount, rename and check (fsck) with the tool's
  output as it runs.
- **Files:** browse a drive, preview, upload, rename, delete.

Download `AirlockCompanion-<version>.dmg` from the
[latest release](https://github.com/emdzej/airlock/releases/latest).
See [macOS companion app](/companion) for install steps and details.

## iPhone and iPad

The same features on iOS and iPadOS 17 or later, plus a **Files app
integration**: every shared drive appears as a location in Files, so
other apps can open and save documents on it directly.

<div class="airlock-shot-row">
  <img src="/screenshots/iphone-light.jpg" alt="Airlock on iPhone, light mode: header card, drives and devices" />
  <img src="/screenshots/iphone-dark.jpg" alt="Airlock on iPhone, dark mode" />
</div>

<div class="airlock-shot">
  <img src="/screenshots/ipad.jpg" alt="Airlock on iPad: sidebar of airlocks next to the drives and devices of the selected one" />
</div>

The iOS app isn't on the App Store yet; it will come to TestFlight
first.

## What the apps need

- An Airlock on the same network (see [Installation](/install)).
  Guest and corporate Wi-Fi often block the Bonjour discovery the
  apps rely on.
- **Local Network** permission, which the apps ask for on first
  launch.

Nothing leaves your network: the apps talk only to Airlock devices on
the LAN, with no accounts and no tracking.
