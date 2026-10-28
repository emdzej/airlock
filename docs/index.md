---
layout: home
title: Mass storage over the network
titleTemplate: Airlock

hero:
  name: Airlock
  text: Mass storage over the network
  tagline: Plug a USB drive, SD card, or external SSD into a Raspberry Pi 4. It appears on your LAN over SMB and HTTP within seconds.
  image:
    light: /hatch-light.svg
    dark: /hatch-dark.svg
    alt: The Airlock hatch
  actions:
    - theme: brand
      text: Get started
      link: /install
    - theme: alt
      text: What is Airlock?
      link: /overview
    - theme: alt
      text: View on GitHub
      link: https://github.com/emdzej/airlock

features:
  - title: Plug and share
    details: Insert any USB thumb drive, SD card, or external SSD — Airlock auto-mounts and exposes it as an SMB share. Reachable from Finder, Explorer, and GNOME Files without any client-side config.
  - title: Web + native apps
    details: Browse files, format drives, flash and dump images, run fsck, and relabel volumes from the built-in web UI, or from the Mac and iPhone/iPad apps, which add silent mount on the Mac and Files integration on iOS.
  - title: Read-only appliance
    details: Ships as a custom pi-gen image with a read-only root filesystem, tmpfs logs, seccomp-hardened systemd unit, and optional BadUSB / Wi-Fi / boot-time hardening.
  - title: Zero-config discovery
    details: Advertised over Bonjour (mDNS) as <code>airlock.local</code> and via a dedicated <code>_airlock._tcp</code> service so companion apps discover instances automatically.
  - title: Handles the ugly filesystems
    details: FAT32, exFAT, NTFS, and ext4 read-write. HFS+ read-only. Format and relabel from the browser without ever touching a shell.
  - title: Physical eject
    details: A GPIO push button on the Pi safely unmounts every drive — and refuses, rather than lazy-unmounting, while a file is still open. A status LED shows mount state at a glance.
---

<div class="airlock-home-apps">

## Native apps for Mac, iPhone and iPad

Everything the web UI does, in apps that find your Airlock by themselves.

<div class="airlock-home-apps__shots">
  <img class="airlock-home-apps__mac" src="/screenshots/mac.webp" alt="Airlock on macOS" />
  <img class="airlock-home-apps__phone" src="/screenshots/iphone-light.jpg" alt="Airlock on iPhone" />
</div>

[See the apps →](/apps)

</div>

