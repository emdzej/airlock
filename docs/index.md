---
layout: home
title: Mass storage over the network
titleTemplate: Airlock

hero:
  name: Airlock
  text: Mass storage over the network
  tagline: Plug a USB drive, SD card, or external SSD into a Raspberry Pi 4. It appears on your LAN over SMB and HTTP within seconds.
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
  - title: Web + native clients
    details: Browse files, format drives, flash and dump images, run fsck, and relabel volumes from the built-in web UI. A macOS menu-bar companion adds silent mount, auto-mount, and live SSE updates.
  - title: Read-only appliance
    details: Ships as a custom pi-gen image with a read-only root filesystem, tmpfs logs, seccomp-hardened systemd unit, and optional BadUSB / Wi-Fi / boot-time hardening.
  - title: Zero-config discovery
    details: Advertised over Bonjour (mDNS) as <code>airlock.local</code> and via a dedicated <code>_airlock._tcp</code> service so companion apps discover instances automatically.
  - title: Handles the ugly filesystems
    details: FAT32, exFAT, NTFS, and ext4 read-write. HFS+ read-only. Format and relabel from the browser without ever touching a shell.
  - title: Physical eject
    details: A GPIO push button on the Pi safely unmounts and powers down the port. A status LED shows mount state at a glance.
---

<style>
:root {
  --vp-c-brand-1: #3aa675;
  --vp-c-brand-2: #55c093;
  --vp-c-brand-3: #6fd3aa;
  --vp-home-hero-name-color: transparent;
  --vp-home-hero-name-background: linear-gradient(120deg, #3aa675 30%, #7ed5c1);
}
</style>
