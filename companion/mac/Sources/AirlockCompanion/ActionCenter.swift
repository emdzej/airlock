import AppKit
import Foundation

/// Objective-C-compatible target that NSMenuItem selectors dispatch
/// to. Holds references to everything the menu actions need.
///
/// Menu items encode their subject via `representedObject`:
///   - `DriveContext`   for per-drive actions
///   - `HostContext`    for per-host actions
///   - Nothing          for global actions
final class ActionCenter: NSObject {
    let discovery: Discovery
    let mounts: MountManager
    let preferencesWindow = PreferencesWindowController()

    init(discovery: Discovery, mounts: MountManager) {
        self.discovery = discovery
        self.mounts = mounts
    }

    // MARK: - Menu actions

    @objc func mountDrive(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        performMount(ctx: ctx, openAfter: Preferences.shared.openOnMount)
    }

    /// Explicit "Mount and Open" menu action: always opens in Finder,
    /// regardless of the `openOnMount` preference.
    @objc func mountAndOpenDrive(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        performMount(ctx: ctx, openAfter: true)
    }

    private func performMount(ctx: DriveContext, openAfter: Bool) {
        mounts.mount(host: ctx.host, drive: ctx.drive) { [weak self] err in
            if let err {
                Notifier.shared.error("Couldn't mount \(ctx.drive.displayName)",
                                      body: err.localizedDescription)
            } else {
                Notifier.shared.info("Mounted \(ctx.drive.displayName)")
                if openAfter { self?.revealMountPath(host: ctx.host, drive: ctx.drive) }
            }
        }
    }

    private func revealMountPath(host: HostState, drive: Drive) {
        // mount() completion fires after the mount table shows the
        // new entry, so mountPath should be populated. Guard anyway.
        guard let mp = mounts.mountPath(host: host, drive: drive) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }

    @objc func unmountDrive(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        mounts.unmount(host: ctx.host, drive: ctx.drive) { err in
            if let err {
                Notifier.shared.error("Couldn't unmount \(ctx.drive.displayName)",
                                      body: err.localizedDescription)
            }
        }
    }

    @objc func revealDrive(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        revealMountPath(host: ctx.host, drive: ctx.drive)
    }

    @objc func ejectDrive(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        // If we hold a local mount, drop it first so the daemon's
        // unmount doesn't fight us.
        let doEject = { [weak self] in
            self?.postEject(host: ctx.host, share: ctx.drive.shareName,
                            label: ctx.drive.displayName)
        }
        if mounts.isMounted(host: ctx.host, drive: ctx.drive) {
            mounts.unmount(host: ctx.host, drive: ctx.drive) { _ in doEject() }
        } else {
            doEject()
        }
    }

    @objc func ejectHost(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? HostContext else { return }
        // Drop every local mount for this host, then hit /api/eject-all.
        for drive in ctx.host.drives where mounts.isMounted(host: ctx.host, drive: drive) {
            mounts.unmount(host: ctx.host, drive: drive) { _ in }
        }
        var req = URLRequest(url: ctx.host.baseURL.appendingPathComponent("api/eject-all"))
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if let err {
                    Notifier.shared.error("Eject failed on \(ctx.host.hostname)",
                                          body: err.localizedDescription)
                } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    Notifier.shared.error("Eject failed on \(ctx.host.hostname)",
                                          body: "HTTP \(http.statusCode)")
                } else {
                    Notifier.shared.info("All drives ejected on \(ctx.host.hostname)")
                }
            }
        }.resume()
    }

    @objc func openWebUI(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? HostContext else { return }
        NSWorkspace.shared.open(ctx.host.baseURL)
    }

    @objc func copySMBURL(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        let host = ctx.host.hostname
        let share = ctx.drive.shareName
        // We're macOS-only, so the smb:// form is right. Windows users
        // paste \\host\share into Explorer; if we ever ship a Windows
        // client we can branch here.
        let text = "smb://\(host)/\(share)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Notifier.shared.info("Copied \(text)")
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        preferencesWindow.show()
    }

    // MARK: - Auto-mount

    /// If a drive we've mounted locally has been ejected on the daemon
    /// side (via web UI, physical button, or format), the Mac's SMB
    /// mount is stale — I/O will fail. Detect gone drives from the
    /// SSE snapshot and unmount them here.
    ///
    /// Skip hosts that went offline entirely — the drive list is
    /// preserved from last-known state, and unmounting on transient
    /// network hiccups would be user-hostile.
    func reconcileEjected() {
        var visibleKeys = Set<String>()
        for host in discovery.hosts where host.isReachable {
            for drive in host.drives {
                visibleKeys.insert("\(host.hostname)/\(drive.shareName)")
            }
        }
        for key in Array(mounts.mountPoints.keys) {
            let hostName = String(key.split(separator: "/", maxSplits: 1).first ?? "")
            // Only reconcile when the owning host is currently reachable
            // — otherwise a Pi reboot would rip mounts out from under us.
            let hostOnline = discovery.hosts.first { $0.hostname == hostName }?.isReachable ?? false
            guard hostOnline else { continue }
            if !visibleKeys.contains(key) {
                let label = key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? key
                mounts.unmountByKey(key) { err in
                    if let err {
                        Notifier.shared.error("Auto-unmount failed: \(label)",
                                              body: err.localizedDescription)
                    } else {
                        Notifier.shared.info("Unmounted \(label)",
                                             body: "Drive was ejected on airlock")
                    }
                }
            }
        }
    }

    /// Auto-mount every currently-visible drive that isn't already
    /// mounted locally. Called after each discovery refresh.
    func maybeAutoMount() {
        guard Preferences.shared.autoMountAll else { return }
        let openAfter = Preferences.shared.openOnMount
        for host in discovery.hosts {
            for drive in host.drives where !mounts.isMounted(host: host, drive: drive) {
                mounts.mount(host: host, drive: drive) { [weak self] err in
                    if let err {
                        Notifier.shared.error("Auto-mount failed: \(drive.displayName)",
                                              body: err.localizedDescription)
                    } else if openAfter {
                        self?.revealMountPath(host: host, drive: drive)
                    }
                }
            }
        }
    }

    // MARK: - Internal

    private func postEject(host: HostState, share: String, label: String) {
        var req = URLRequest(url: host.baseURL
            .appendingPathComponent("api/drives")
            .appendingPathComponent(share)
            .appendingPathComponent("eject"))
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if let err {
                    Notifier.shared.error("Eject failed: \(label)",
                                          body: err.localizedDescription)
                } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    Notifier.shared.error("Eject failed: \(label)",
                                          body: "HTTP \(http.statusCode)")
                } else {
                    Notifier.shared.info("Ejected \(label)")
                }
            }
        }.resume()
    }
}

/// Menu-item payload identifying which host + drive to act on.
final class DriveContext: NSObject {
    let host: HostState
    let drive: Drive
    init(host: HostState, drive: Drive) {
        self.host = host
        self.drive = drive
    }
}

/// Menu-item payload identifying which host to act on.
final class HostContext: NSObject {
    let host: HostState
    init(host: HostState) { self.host = host }
}
