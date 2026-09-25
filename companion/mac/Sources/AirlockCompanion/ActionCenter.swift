import AppKit
import Foundation

/// Objective-C-compatible target that NSMenuItem selectors dispatch
/// to. Holds references to everything the menu actions need.
///
/// Menu items encode their subject via `representedObject`:
///   - `DriveContext`   for per-drive actions
///   - `HostContext`    for per-host actions
///   - Nothing          for global actions
@MainActor
final class ActionCenter: NSObject {
    let discovery: Discovery
    let mounts: MountManager
    let preferencesWindow = PreferencesWindowController()

    /// `<host>/<share>` keys the user deliberately unmounted (menu
    /// Unmount, eject, Finder eject). Auto-mount leaves these alone
    /// until the drive disappears from its host's snapshot.
    private var dismissed = Set<String>()

    /// Auto-mount failure bookkeeping per key: consecutive failures and
    /// when we may try again. Only the first failure notifies.
    private var autoMountFailures: [String: (count: Int, retryAfter: Date)] = [:]

    init(discovery: Discovery, mounts: MountManager) {
        self.discovery = discovery
        self.mounts = mounts
        super.init()
        mounts.onExternalUnmount = { [weak self] key in self?.externallyUnmounted(key) }
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
        let key = mounts.key(host: ctx.host, drive: ctx.drive)
        // An explicit mount overrides any earlier dismissal / backoff.
        dismissed.remove(key)
        autoMountFailures.removeValue(forKey: key)
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
        let key = mounts.key(host: ctx.host, drive: ctx.drive)
        let wasDismissed = dismissed.contains(key)
        dismissed.insert(key)
        mounts.unmount(host: ctx.host, drive: ctx.drive) { [weak self] err in
            if let err {
                if !wasDismissed { self?.dismissed.remove(key) }
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
        let label = ctx.drive.displayName
        let doEject = { [weak self] in
            guard let self else { return }
            self.post(self.driveEjectURL(host: ctx.host, share: ctx.drive.shareName)) { failure in
                if let failure {
                    Notifier.shared.error("Eject failed: \(label)", body: failure)
                } else {
                    Notifier.shared.info("Ejected \(label)")
                }
            }
        }
        // Keep auto-mount from grabbing the drive back while the
        // daemon ejects it; cleared once it leaves the snapshot.
        dismissed.insert(mounts.key(host: ctx.host, drive: ctx.drive))
        guard mounts.isMounted(host: ctx.host, drive: ctx.drive) else { return doEject() }
        // Drop our local mount first. If that fails (files open), don't
        // pull the drive out from under it — tell the user instead.
        mounts.unmount(host: ctx.host, drive: ctx.drive) { err in
            if let err {
                Notifier.shared.error("Couldn't eject \(label)",
                                      body: "Unmount on this Mac failed: \(err.localizedDescription)")
            } else {
                doEject()
            }
        }
    }

    @objc func ejectHost(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? HostContext else { return }
        let host = ctx.host
        let doEject = { [weak self] in
            guard let self else { return }
            self.post(host.baseURL.appendingPathComponent("api/eject-all")) { failure in
                if let failure {
                    Notifier.shared.error("Eject failed on \(host.serviceName)", body: failure)
                } else {
                    Notifier.shared.info("All drives ejected on \(host.serviceName)")
                }
            }
        }
        // Drop every local mount for this host, wait for all of them,
        // and only then hit /api/eject-all. Any busy mount aborts.
        let mounted = host.drives.filter { mounts.isMounted(host: host, drive: $0) }
        for drive in host.drives { dismissed.insert(mounts.key(host: host, drive: drive)) }
        guard !mounted.isEmpty else { return doEject() }
        var remaining = mounted.count
        var failures: [String] = []
        for drive in mounted {
            mounts.unmount(host: host, drive: drive) { err in
                if let err { failures.append("\(drive.displayName): \(err.localizedDescription)") }
                remaining -= 1
                guard remaining == 0 else { return }
                if failures.isEmpty {
                    doEject()
                } else {
                    Notifier.shared.error("Couldn't eject drives on \(host.serviceName)",
                                          body: "Unmount on this Mac failed — " + failures.joined(separator: "; "))
                }
            }
        }
    }

    @objc func openWebUI(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? HostContext else { return }
        NSWorkspace.shared.open(ctx.host.baseURL)
    }

    @objc func copySMBURL(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? DriveContext else { return }
        let host = ctx.host.hostname
        let share = MountManager.encodedShare(ctx.drive.shareName)
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
    /// SSE snapshot and unmount them here. Also forgets dismissals and
    /// auto-mount failures for drives that have left the snapshot, so
    /// a re-plugged drive auto-mounts again.
    ///
    /// Drives the daemon reports as `ejecting` count as gone for the
    /// unmount (their share is already withdrawn) but not for clearing
    /// dismissals — a busy eject can leave them in place.
    ///
    /// Skip hosts that went offline entirely — the drive list is
    /// preserved from last-known state, and unmounting on transient
    /// network hiccups would be user-hostile.
    func reconcileEjected() {
        var onlineHosts = Set<String>()
        var visibleKeys = Set<String>()
        var ejectingKeys = Set<String>()
        for host in discovery.hosts where host.isReachable {
            onlineHosts.insert(host.hostname)
            for drive in host.drives {
                let key = mounts.key(host: host, drive: drive)
                visibleKeys.insert(key)
                if drive.ejecting { ejectingKeys.insert(key) }
            }
        }
        // Only reconcile when the owning host is currently reachable
        // — otherwise a Pi reboot would rip mounts out from under us.
        let isGone: (String) -> Bool = { key in
            let hostName = String(key.split(separator: "/", maxSplits: 1).first ?? "")
            return onlineHosts.contains(hostName) && !visibleKeys.contains(key)
        }
        dismissed = dismissed.filter { !isGone($0) }
        autoMountFailures = autoMountFailures.filter { !isGone($0.key) }

        for key in Array(mounts.mountPoints.keys) where isGone(key) || ejectingKeys.contains(key) {
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

    /// Auto-mount every currently-visible drive that isn't already
    /// mounted locally. Called after each discovery refresh. Skips
    /// offline hosts (cached drive lists), drives mid-eject on the
    /// daemon, drives the user dismissed,
    /// mounts already in flight, and drives in failure backoff.
    func maybeAutoMount() {
        guard Preferences.shared.autoMountAll else { return }
        let openAfter = Preferences.shared.openOnMount
        let now = Date()
        for host in discovery.hosts where host.isReachable {
            for drive in host.drives {
                let key = mounts.key(host: host, drive: drive)
                guard !drive.ejecting,
                      !mounts.isMounted(host: host, drive: drive),
                      !mounts.isMounting(host: host, drive: drive),
                      !dismissed.contains(key) else { continue }
                if let f = autoMountFailures[key], f.retryAfter > now { continue }
                mounts.mount(host: host, drive: drive) { [weak self] err in
                    guard let self else { return }
                    if let err {
                        self.autoMountFailed(key: key, label: drive.displayName, error: err)
                    } else {
                        self.autoMountFailures.removeValue(forKey: key)
                        if openAfter { self.revealMountPath(host: host, drive: drive) }
                    }
                }
            }
        }
    }

    /// Exponential backoff (30 s, 60 s, … capped at 10 min) with a
    /// timer to retry, since nothing else may trigger a refresh.
    private func autoMountFailed(key: String, label: String, error: Error) {
        let count = (autoMountFailures[key]?.count ?? 0) + 1
        let delay = min(30 * pow(2, Double(count - 1)), 600)
        autoMountFailures[key] = (count, Date().addingTimeInterval(delay))
        if count == 1 {
            Notifier.shared.error("Auto-mount failed: \(label)",
                                  body: error.localizedDescription + " — will keep retrying quietly.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.maybeAutoMount() }
        }
    }

    /// A mount vanished without us unmounting it (Finder eject, etc.).
    /// Treat as a user dismissal — but only while the host is online;
    /// macOS dropping a dead server shouldn't block re-mount later.
    private func externallyUnmounted(_ key: String) {
        let hostName = String(key.split(separator: "/", maxSplits: 1).first ?? "")
        let online = discovery.hosts.first { $0.hostname == hostName }?.isReachable ?? false
        if online { dismissed.insert(key) }
    }

    // MARK: - Internal

    private func driveEjectURL(host: HostState, share: String) -> URL {
        return host.baseURL
            .appendingPathComponent("api/drives")
            .appendingPathComponent(share)
            .appendingPathComponent("eject")
    }

    /// POST to the daemon; `done` gets nil on 2xx or a short failure
    /// description, on the main actor. Non-2xx responses carry
    /// `{"error": "..."}` (e.g. 409 when the filesystem is busy) — that
    /// message is surfaced in preference to the bare status code.
    private func post(_ url: URL, done: @escaping @MainActor @Sendable (String?) -> Void) {
        struct ErrorBody: Decodable { let error: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let failure: String?
            if let err {
                failure = err.localizedDescription
            } else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = data.flatMap { try? JSONDecoder().decode(ErrorBody.self, from: $0) }?.error
                failure = msg.map { "\($0) (HTTP \(http.statusCode))" } ?? "HTTP \(http.statusCode)"
            } else {
                failure = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(failure) }
            }
        }.resume()
    }
}

/// Menu-item payload identifying which host + drive to act on.
@MainActor
final class DriveContext: NSObject {
    let host: HostState
    let drive: Drive
    init(host: HostState, drive: Drive) {
        self.host = host
        self.drive = drive
    }
}

/// Menu-item payload identifying which host to act on.
@MainActor
final class HostContext: NSObject {
    let host: HostState
    init(host: HostState) { self.host = host }
}
