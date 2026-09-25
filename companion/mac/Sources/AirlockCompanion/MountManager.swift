import Foundation
import AppKit
import NetFS

/// Tracks local SMB mounts of airlock shares. Mounts go through
/// `NetFSMountURLSync` — the same NetFS path Finder's ⌘K uses, but
/// with no UI — because manually mkdir'ing under `/Volumes/` requires
/// root and we don't ship a privileged helper.
///
/// State is derived from the kernel mount table (`getfsstat`): each
/// smbfs entry's source looks like `//user@host/share`. We key mounts
/// by `<host>/<share>`; if macOS auto-suffixes the mount point
/// because of a name collision (`/Volumes/kingston-1`), we honor
/// that path.
@MainActor
final class MountManager {
    typealias Completion = @MainActor (Error?) -> Void

    /// Fires on mount, unmount, or system mount table change.
    var onChange: (() -> Void)?

    /// Fires with the `<host>/<share>` key of a mount that disappeared
    /// without us unmounting it — i.e. Finder eject, `umount` in a
    /// terminal, or macOS dropping a dead server.
    var onExternalUnmount: ((String) -> Void)?

    /// `<hostname>/<share>` → local mount path.
    private(set) var mountPoints: [String: String] = [:]

    /// Keys with a NetFS mount in progress → completions waiting on it.
    /// A second mount request for the same key joins the first rather
    /// than producing a duplicate `/Volumes/<share>-1` mount.
    private var mountsInFlight: [String: [Completion]] = [:]

    /// Keys we're unmounting ourselves → completions waiting on it.
    /// Also lets refresh() tell our own unmounts from external ones.
    private var unmountsInFlight: [String: [Completion]] = [:]

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Mount-table key for a drive on a host.
    func key(host: HostState, drive: Drive) -> String {
        return Self.key(hostname: host.hostname, share: drive.shareName)
    }

    static func key(hostname: String, share: String) -> String {
        return "\(hostname)/\(share)"
    }

    /// Percent-encode a share name for use as an smb:// URL path
    /// component (spaces, `#`, `%`, `/` …).
    static func encodedShare(_ share: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return share.addingPercentEncoding(withAllowedCharacters: allowed) ?? share
    }

    /// The current local mount path for a drive, or nil if we don't
    /// have a mount for it. Path is macOS-assigned (usually
    /// `/Volumes/<share>` or `/Volumes/<share>-1` on collision).
    func mountPath(host: HostState, drive: Drive) -> String? {
        return mountPoints[key(host: host, drive: drive)]
    }

    func isMounted(host: HostState, drive: Drive) -> Bool {
        return mountPath(host: host, drive: drive) != nil
    }

    func isMounting(host: HostState, drive: Drive) -> Bool {
        return mountsInFlight[key(host: host, drive: drive)] != nil
    }

    /// Mount `drive` from `host` silently via NetFSMountURLSync.
    /// Unlike NSWorkspace.open(smb://) — which opens a Finder window
    /// on every successful mount — this hits the same DiskArbitration
    /// path as Finder without any UI. `mountPath` is populated as
    /// soon as the underlying `mount(2)` returns; no polling needed.
    func mount(host: HostState, drive: Drive, completion: @escaping Completion) {
        let key = key(host: host, drive: drive)
        if mountsInFlight[key] != nil {
            mountsInFlight[key]?.append(completion)
            return
        }
        guard let url = smbURL(host: host, drive: drive) else {
            completion(NSError(domain: "airlock.mount", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "invalid SMB URL"]))
            return
        }
        mountsInFlight[key] = [completion]
        // NetFSMountURLSync blocks — run off the main queue. Strong
        // self: MountManager lives for the app's lifetime anyway.
        DispatchQueue.global(qos: .utility).async {
            // kNAUIOptionNoUI: fail instead of popping an auth / server
            // picker dialog if guest access is refused.
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            var mountedRef: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, nil, nil, nil,
                                           openOptions as CFMutableDictionary, nil, &mountedRef)
            let paths: [String] = (mountedRef?.takeRetainedValue() as? [String]) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishMount(key: key, status: status, paths: paths)
                }
            }
        }
    }

    private func finishMount(key: String, status: Int32, paths: [String]) {
        let waiters = mountsInFlight.removeValue(forKey: key) ?? []
        var err: Error?
        if status == 0 {
            // If the mount table hasn't updated by the time we're
            // called, seed it from the paths NetFS just returned.
            // Later refresh() calls reconcile.
            if let path = paths.first {
                mountPoints[key] = path
            }
            refresh()
        } else {
            err = NSError(domain: "airlock.mount", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: Self.netFSErrorMessage(status)])
        }
        for w in waiters { w(err) }
    }

    /// Translate NetFS status codes into human-readable messages.
    /// Most are POSIX errno values (permission denied, host down, etc.)
    /// — strerror covers those. A few are NetFS-specific negatives
    /// (e.g. -6600 series) and pass through as-is.
    private static func netFSErrorMessage(_ status: Int32) -> String {
        if status > 0 {
            return String(cString: strerror(status))
        }
        return "NetFS error \(status)"
    }

    /// Unmount `drive` from `host` via `/sbin/umount`. Best-effort —
    /// `umount` fails if a Finder window has files open.
    func unmount(host: HostState, drive: Drive, completion: @escaping Completion) {
        unmountByKey(key(host: host, drive: drive), completion: completion)
    }

    /// Unmount whichever local mount is keyed by "<host>/<share>".
    /// Used for reconciliation after the daemon reports an ejection —
    /// we may no longer have a Drive object for the vanished share.
    func unmountByKey(_ key: String, completion: @escaping Completion) {
        guard let mp = mountPoints[key] else {
            completion(nil)
            return
        }
        if unmountsInFlight[key] != nil {
            unmountsInFlight[key]?.append(completion)
            return
        }
        unmountsInFlight[key] = [completion]
        Self.run("/sbin/umount", [mp]) { [weak self] err in
            self?.finishUnmount(key: key, error: err)
        }
    }

    private func finishUnmount(key: String, error: Error?) {
        if error == nil, mountPoints.removeValue(forKey: key) != nil {
            onChange?()
        }
        let waiters = unmountsInFlight.removeValue(forKey: key) ?? []
        for w in waiters { w(error) }
    }

    /// Re-read the kernel mount table and rebuild `mountPoints`.
    func refresh() {
        var next: [String: String] = [:]
        for entry in Self.smbMounts() {
            next[Self.key(hostname: entry.host, share: entry.share)] = entry.path
        }
        // Only fire onChange when something actually changed —
        // NSWorkspace notifications fire on every mount event system-
        // wide, including ones we don't care about.
        guard next != mountPoints else { return }
        let vanished = Set(mountPoints.keys).subtracting(next.keys).subtracting(unmountsInFlight.keys)
        mountPoints = next
        for key in vanished { onExternalUnmount?(key) }
        onChange?()
    }

    // MARK: - Internal

    private func smbURL(host: HostState, drive: Drive) -> URL? {
        // `guest:@…` triggers macOS's guest auth without a keychain
        // prompt — matches airlock's no-auth SMB config.
        return URL(string: "smb://guest:@\(host.hostname)/\(Self.encodedShare(drive.shareName))")
    }

    /// Every smbfs entry in the kernel mount table. `MNT_NOWAIT`
    /// returns cached stats, so a hung SMB server can't block us.
    private static func smbMounts() -> [(host: String, share: String, path: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Headroom in case something mounts between the two calls.
        var buf: [statfs] = .init(repeating: .init(), count: Int(count) + 8)
        let got = buf.withUnsafeMutableBufferPointer { p in
            getfsstat(p.baseAddress, Int32(p.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return [] }
        var out: [(host: String, share: String, path: String)] = []
        for var fs in buf.prefix(Int(got)) {
            let type = cString(&fs.f_fstypename)
            guard type == "smbfs" else { continue }
            guard let parsed = parseSource(cString(&fs.f_mntfromname)) else { continue }
            out.append((parsed.host, parsed.share, cString(&fs.f_mntonname)))
        }
        return out
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }

    /// Parse an smbfs mount source into host + share.
    ///
    /// Format examples:
    ///   //guest@airlock.local/malenstwo
    ///   //user:pw@nas/media
    private static func parseSource(_ source: String) -> (host: String, share: String)? {
        guard source.hasPrefix("//") else { return nil }
        // Strip any `user[:pw]@` prefix on the source.
        var tail = String(source.dropFirst(2))
        if let atIdx = tail.lastIndex(of: "@") {
            tail = String(tail[tail.index(after: atIdx)...])
        }
        guard let slash = tail.firstIndex(of: "/") else { return nil }
        let host = String(tail[..<slash])
        let share = String(tail[tail.index(after: slash)...])
        // macOS URL-decodes shares in mount records but not always;
        // normalise so we can compare against drive.shareName.
        let decodedShare = share.removingPercentEncoding ?? share
        return (host, decodedShare)
    }

    /// Run a tool off the main thread and call back on main with nil or
    /// an error carrying its stderr. Reads the pipe to EOF before
    /// waiting so a chatty tool can't deadlock on a full pipe buffer.
    private static func run(_ path: String, _ args: [String],
                            done: @escaping @MainActor @Sendable (Error?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = FileHandle.nullDevice
            var result: Error?
            do {
                try task.run()
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = NSError(domain: "com.emdzej.airlock.companion",
                                     code: Int(task.terminationStatus),
                                     userInfo: [NSLocalizedDescriptionKey:
                                                msg.isEmpty ? "\(path) exit \(task.terminationStatus)" : msg])
                }
            } catch {
                result = error
            }
            let err = result
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(err) }
            }
        }
    }
}
