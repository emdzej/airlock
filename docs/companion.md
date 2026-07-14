# macOS companion app

`AirlockCompanion.app` is a small **menu-bar client** for macOS 13+
that discovers every Airlock on your LAN and lets you mount, unmount,
and eject drives without leaving your keyboard.

- Menu-bar only (`LSUIElement`) — no Dock icon, no windows unless you
  open Preferences.
- Auto-discovery via Bonjour on the `_airlock._tcp` service type —
  no configuration, no hostnames to remember.
- Silent mount via `NetFSMountURLSync` from `NetFS.framework`; the
  same DiskArbitration path Finder uses, but no Finder window pops.
- Live updates via Server-Sent Events from the daemon — drives
  appear and disappear in the menu within a second of physical
  insertion or ejection.

## Install

The companion ships as an **ad-hoc-signed, un-notarized** DMG (no
Apple Developer Account at time of writing). The ad-hoc signature
satisfies Gatekeeper's *integrity* check, but the app still isn't
trusted by Apple, so macOS refuses to open it on first launch. One
manual step gets past that.

1. Download `AirlockCompanion-<version>.dmg` from the
   [latest GitHub release](https://github.com/emdzej/airlock/releases/latest).
2. Open the DMG and drag `AirlockCompanion.app` to `/Applications`.
   Eject the DMG afterwards — running the app directly from the DMG's
   read-only mount is what triggers the harshest "damaged" prompt.
3. Strip the quarantine xattr from the copy in `/Applications`:
   ```sh
   xattr -dr com.apple.quarantine /Applications/AirlockCompanion.app
   ```
   Then double-click to launch.
4. Grant **Local Network** access when macOS prompts — the app needs
   it to browse Bonjour and connect to airlock instances over LAN.

### Why the extra step?

macOS 15 (Sequoia) tightened Gatekeeper: unsigned or un-notarized
apps launched from a downloaded DMG can no longer be bypassed with
the old **right-click → Open** trick. macOS shows:

> **"AirlockCompanion.app" is damaged and can't be opened.**
> You should eject the disk image.

That's the quarantine attribute (`com.apple.quarantine`, set by
Safari on every download) being enforced strictly against an app
without a *notarized* signature. Ad-hoc signing fixes the "damaged"
integrity failure, but the quarantine attribute still has to be
cleared for Gatekeeper to run the binary — hence the one-off `xattr`
command.

Once launched once, macOS records the approval; subsequent launches
work with no prompts.

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
