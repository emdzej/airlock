import Foundation
import AppKit

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

    /// Mount `drive` from `host`. Hands off to macOS's SMB mounter
    /// via `open smb://guest:@host/share`. Completion fires once the
    /// mount table reflects the new mount (up to 3 s wait).
    func mount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        guard let url = smbURL(host: host, drive: drive) else {
            completion(NSError(domain: "airlock.mount", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "invalid SMB URL"]))
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false // don't bring Finder to the foreground
        NSWorkspace.shared.open(url, configuration: cfg) { [weak self] _, err in
            DispatchQueue.main.async {
                if let err {
                    completion(err)
                    return
                }
                // NSWorkspace.open resolves as soon as the URL is
                // handed to Finder, not when the mount is complete.
                // Poll the mount table for a short window.
                self?.waitForMount(host: host, drive: drive, tries: 12) { ok in
                    self?.refresh()
                    if ok {
                        completion(nil)
                    } else {
                        completion(NSError(domain: "airlock.mount", code: -2,
                                           userInfo: [NSLocalizedDescriptionKey: "mount didn't appear in mount table"]))
                    }
                }
            }
        }
    }

    /// Unmount `drive` from `host` via `/sbin/umount`. Best-effort —
    /// `umount` fails if a Finder window has files open.
    func unmount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        guard let mp = mountPath(host: host, drive: drive) else {
            completion(nil)
            return
        }
        run("/sbin/umount", [mp]) { [weak self] err in
            if err == nil {
                self?.mountPoints.removeValue(forKey: self!.key(host: host, drive: drive))
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

    private func waitForMount(host: HostState, drive: Drive,
                              tries: Int,
                              completion: @escaping (Bool) -> Void) {
        var remaining = tries
        func tick() {
            let out = shell("/sbin/mount")
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if let entry = parseMountLine(String(line)),
                   entry.host == hostKey(host),
                   entry.share == drive.shareName {
                    completion(true)
                    return
                }
            }
            remaining -= 1
            if remaining <= 0 {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tick() }
        }
        tick()
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
