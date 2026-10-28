# macOS companion app

`AirlockCompanion.app` is a **menu-bar client** for macOS 14+ that
discovers every Airlock on your LAN and lets you mount, unmount, and
eject drives without leaving your keyboard. **Open Airlock…** (⌘O in
the menu) opens a window with everything the web UI does: drives,
devices, format, flash, dump, fsck, relabel, mount and a file browser.

- Menu-bar first (`LSUIElement`): it shows in the Dock only while the
  Airlock window is open. The window opens by itself on first launch,
  with setup steps if no Airlock has been found yet.
- **Forget** an Airlock you no longer use from its menu section or the
  window's sidebar; it comes back if it's still on the network.
- Auto-discovery via Bonjour on the `_airlock._tcp` service type —
  no configuration, no hostnames to remember.
- Silent mount via `NetFSMountURLSync` from `NetFS.framework`; the
  same DiskArbitration path Finder uses, but no Finder window pops.
- Live updates via Server-Sent Events from the daemon — drives
  appear and disappear in the menu within a second of physical
  insertion or ejection.

## Install

1. Download `AirlockCompanion-<version>.dmg` from the
   [latest GitHub release](https://github.com/emdzej/airlock/releases/latest).
2. Open the DMG and drag `AirlockCompanion.app` to `/Applications`.
3. Launch it. The Airlock window opens on first launch.
4. Grant **Local Network** access when macOS asks: the app needs it to
   browse Bonjour and reach airlock instances on your LAN.

From 0.5.0 the DMG and the app are signed with a Developer ID and
notarised by Apple, so they open with a double-click.

### Releases before 0.5.0

Those DMGs were only ad-hoc signed, and macOS 15 calls the app
**"damaged and can't be opened"** when it comes from a download. Clear
the download's quarantine flag once, then launch it:

```sh
xattr -dr com.apple.quarantine /Applications/AirlockCompanion.app
```

## Menu layout

Click the airlock icon in the menu bar:

```
● malenstwo.local                        (green dot: live)
    Drives
      ├─ 💾 MALENSTWO  (mounted at ~/…)
      │    Unmount
      │    Reveal in Finder
      │    Copy SMB URL
      │    Eject from airlock
      └─ 💾 SDCARD     (not mounted locally)
           Mount on this Mac
           Mount and Open in Finder
           Copy SMB URL
           Eject from airlock
    Actions
      Eject all drives
      Open web UI…

○ garaz.local                            (grey dot: offline · 2h ago)
    Cached drives shown for reference; actions disabled.

──────────────
Preferences…
Quit
```

- **Green dot** — SSE connection live, drive list is up to date.
- **Grey dot** — host is currently offline. Drive list is the last
  known snapshot, displayed for reference; mount actions are
  disabled.
- **Red dot** — connection error; hover for the message. Auto-retries
  with exponential backoff.

## Preferences

Choose **Preferences…** from the menu:

| Toggle | What it does |
|---|---|
| **Auto-mount all discovered drives** | Every drive that appears on any Airlock on your LAN is mounted on this Mac automatically. Off by default. |
| **Open in Finder after mounting** | Reveal the drive in Finder the moment it mounts — for both the auto-mount above and the plain **Mount on this Mac** action. Off by default, since the drive is available in Finder's sidebar anyway. |
| **Start at login** | Registers the app with `SMAppService`. Approval is granted automatically on first toggle; if macOS says "Approval pending", enable Airlock Companion under **System Settings → General → Login Items**. |

The footer of the Preferences window shows the running app version
and a link to the source repo.

## Auto-unmount on eject

If you eject a drive **on the daemon side** — either from the web UI,
the physical GPIO button, or by triggering a format — the Mac's local
SMB mount is left pointing at a share that no longer exists. Every
read from that mount would then fail with `EIO`.

The companion detects this from the SSE event stream and unmounts
the stale mount automatically. A notification confirms the drop:

> **Unmounted MALENSTWO**
> Drive was ejected on airlock

Reconciliation only fires when the owning airlock is still
**reachable** — a transient Pi reboot or Wi-Fi hiccup won't rip live
mounts away from you.

## Persistent host store

The app remembers every Airlock it has seen, keyed by hostname, in
`~/Library/Preferences/…/knownHosts`. Airlocks that are currently
offline still appear in the menu with an `offline · 2h ago` label
and their last-known drive list — useful when you know which one
you want to power on. Entries older than **30 days** are pruned.

## Troubleshooting

**"Mount on this Mac" fails with a permission error.**
Old versions used `NSWorkspace.open(smb://…)` and could fall back to
`mkdir /Volumes/…` under sandbox constraints. Since **0.3.0** the
companion uses `NetFSMountURLSync`, which hits DiskArbitration
directly and doesn't need `/Volumes/` write permission. Update to
the latest release.

**Companion sees the Airlock but no drives.**
Check the daemon's SSE stream is live:

```sh
curl -N http://<host>/api/events
```

You should see a heartbeat every 30 s and a `drives` event after
insertion. If polling shows drives but SSE stays silent, the daemon
version predates 0.3.0 — upgrade the Pi.

**Bonjour discovery isn't finding my Airlock.**
Confirm the daemon advertises `_airlock._tcp`:

```sh
dns-sd -B _airlock._tcp .
```

If the service doesn't appear, the Pi is on a different broadcast
domain (common on guest / IoT VLANs) or `avahi-daemon` isn't
running.

**I want to start over.**
Quit the app, then delete `~/Library/Preferences/com.emdzej.airlock.companion.plist`
and any mounted shares under `/Volumes/`. Relaunch.

## Under the hood

The companion is a pure Swift Package (`companion/mac/`, ~1500 LoC)
wrapped into a `.app` bundle by `build.sh`. Notable pieces:

- **`Discovery.swift`** — `NWBrowser` on `_airlock._tcp`, backed by
  `HostStore` for persistence.
- **`EventStream.swift`** — `URLSessionDataDelegate`-based SSE parser
  (bytes not lines — `URLSession.bytes(for:).lines` coalesces small
  frames and drops them on macOS 13/14).
- **`MountManager.swift`** — `NetFSMountURLSync` for silent mount,
  `/sbin/umount` for unmount, `/sbin/mount` output parsing for
  ground truth.
- **`ActionCenter.swift`** — orchestrates auto-mount and
  reconcile-on-eject, running after every discovery/SSE event.

Source: [`companion/mac/`](https://github.com/emdzej/airlock/tree/main/companion/mac).
