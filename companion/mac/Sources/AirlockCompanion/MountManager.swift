import Foundation
import AppKit
import NetFS

/// Tracks local SMB mounts of airlock shares. Mounts are delegated to
/// macOS's built-in SMB mounter (via `NSWorkspace.open(smb://…)`) —
/// same code path Finder uses for ⌘K — because manually mkdir'ing
/// under `/Volumes/` requires root and we don't ship a privileged
/// helper.
///
/// State is derived from parsing `/sbin/mount` output: each SMB row
/// looks like `//user@host/share on /path (smbfs, …)`. We key mounts
/// by `<host>/<share>`; if macOS auto-suffixes the mount point
/// because of a name collision (`/Volumes/kingston-1`), we honor
/// that path.
final class MountManager {
    /// Fires on mount, unmount, or system mount table change.
    var onChange: (() -> Void)?

    /// `<hostname>/<share>` → local mount path.
    private(set) var mountPoints: [String: String] = [:]

    init() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
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

    /// Mount `drive` from `host` silently via NetFSMountURLSync.
    /// Unlike NSWorkspace.open(smb://) — which opens a Finder window
    /// on every successful mount — this hits the same DiskArbitration
    /// path as Finder without any UI. `mountPath` is populated as
    /// soon as the underlying `mount(2)` returns; no polling needed.
    func mount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        guard let url = smbURL(host: host, drive: drive) as CFURL? else {
            completion(NSError(domain: "airlock.mount", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "invalid SMB URL"]))
            return
        }
        // NetFSMountURLSync blocks — run off the main queue.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var mountedRef: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url, nil, nil, nil, nil, nil, &mountedRef)
            let paths: [String] = (mountedRef?.takeRetainedValue() as? [String]) ?? []
            DispatchQueue.main.async {
                if status == 0 {
                    // If the mount table hasn't updated by the time
                    // we're called, seed it from the paths NetFS just
                    // returned. Later refresh() calls reconcile.
                    if let path = paths.first {
                        self?.mountPoints[self!.key(host: host, drive: drive)] = path
                    }
                    self?.refresh()
                    completion(nil)
                } else {
                    completion(NSError(
                        domain: "airlock.mount",
                        code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: Self.netFSErrorMessage(status)]))
                }
            }
        }
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
    func unmount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        unmountByKey(key(host: host, drive: drive), completion: completion)
    }

    /// Unmount whichever local mount is keyed by "<host>/<share>".
    /// Used for reconciliation after the daemon reports an ejection —
    /// we may no longer have a Drive object for the vanished share.
    func unmountByKey(_ key: String, completion: @escaping (Error?) -> Void) {
        guard let mp = mountPoints[key] else {
            completion(nil)
            return
        }
        run("/sbin/umount", [mp]) { [weak self] err in
            if err == nil {
                self?.mountPoints.removeValue(forKey: key)
                self?.onChange?()
            }
            completion(err)
        }
    }

    /// Parse `mount` output and rebuild the mount table.
    func refresh() {
        let output = shell("/sbin/mount")
        var next: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard let entry = parseMountLine(s) else { continue }
            next["\(entry.host)/\(entry.share)"] = entry.path
        }
        // Only fire onChange when something actually changed —
        // NSWorkspace notifications fire on every mount event system-
        // wide, including ones we don't care about.
        if next != mountPoints {
            mountPoints = next
            onChange?()
        }
    }

    // MARK: - Internal

    private func key(host: HostState, drive: Drive) -> String {
        return "\(hostKey(host))/\(drive.shareName)"
    }

    /// The hostname string macOS actually uses in mount records
    /// (usually the mDNS/DNS name we passed to `smb://…`).
    private func hostKey(_ host: HostState) -> String {
        return host.hostname
    }

    private func smbURL(host: HostState, drive: Drive) -> URL? {
        // `guest:@…` triggers macOS's guest auth without a keychain
        // prompt — matches airlock's no-auth SMB config.
        let allowed = CharacterSet.urlPathAllowed
        let share = drive.shareName.addingPercentEncoding(withAllowedCharacters: allowed) ?? drive.shareName
        return URL(string: "smb://guest:@\(host.hostname)/\(share)")
    }

    /// Parse a single `mount` line for an SMB entry.
    ///
    /// Format examples:
    ///   //guest@airlock.local/malenstwo on /Volumes/malenstwo (smbfs, nodev, nosuid, …)
    ///   //user:pw@nas/media on /Volumes/media-1 (smbfs, …)
    private func parseMountLine(_ line: String) -> (host: String, share: String, path: String)? {
        guard line.hasPrefix("//") else { return nil }
        guard let onRange = line.range(of: " on ") else { return nil }
        let source = String(line[line.index(line.startIndex, offsetBy: 2)..<onRange.lowerBound])
        let rest = line[onRange.upperBound...]
        guard let parenRange = rest.range(of: " (") else { return nil }
        let path = String(rest[..<parenRange.lowerBound])
        let opts = String(rest[parenRange.upperBound...])
        guard opts.hasPrefix("smbfs") else { return nil }

        // Strip any `user[:pw]@` prefix on the source.
        var tail = source
        if let atIdx = tail.lastIndex(of: "@") {
            tail = String(tail[tail.index(after: atIdx)...])
        }
        guard let slash = tail.firstIndex(of: "/") else { return nil }
        let host = String(tail[..<slash])
        let share = String(tail[tail.index(after: slash)...])
        // macOS URL-decodes shares in mount output but not always;
        // normalise so we can compare against drive.shareName.
        let decodedShare = share.removingPercentEncoding ?? share
        return (host, decodedShare, path)
    }

    private func shell(_ path: String, _ args: [String] = []) -> String {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    private func run(_ launchPath: String, _ args: [String], done: @escaping (Error?) -> Void) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        task.terminationHandler = { proc in
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    done(nil)
                } else {
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    done(NSError(domain: "com.emdzej.airlock.companion",
                                 code: Int(proc.terminationStatus),
                                 userInfo: [NSLocalizedDescriptionKey:
                                            msg.isEmpty ? "\(launchPath) exit \(proc.terminationStatus)" : msg]))
                }
            }
        }
        do {
            try task.run()
        } catch {
            DispatchQueue.main.async { done(error) }
        }
    }
}
