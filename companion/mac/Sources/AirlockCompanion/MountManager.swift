import Foundation
import AppKit

/// Owns local SMB mounts made by the companion app. Mount points
/// follow the convention `/Volumes/<share>-on-<host>` so drives with
/// the same label across multiple airlocks don't collide.
///
/// Tracks which of those mount points are currently live by scanning
/// `FileManager.mountedVolumeURLs`; not authoritative for mounts
/// created outside the app (Finder ⌘K, other tools) — those have
/// different mount-point paths.
final class MountManager {
    /// Fires after a mount / unmount finishes (either direction).
    var onChange: (() -> Void)?

    /// Current on-disk mount points we own, keyed by "<host>/<share>".
    private(set) var mountPoints: [String: String] = [:]

    init() {
        refresh()
        // Refresh when a volume appears or disappears — Finder / diskutil
        // events flow through NSWorkspace.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    /// Mount-point path the app would use for `drive` on `host`. Not
    /// a promise the volume is actually mounted — check `isMounted`.
    func mountPointFor(host: HostState, drive: Drive) -> String {
        let share = sanitize(drive.shareName)
        let hostname = sanitize(host.hostname.replacingOccurrences(of: ".local", with: ""))
        return "/Volumes/\(share)-on-\(hostname)"
    }

    func isMounted(host: HostState, drive: Drive) -> Bool {
        return mountPoints[key(host: host, drive: drive)] != nil
    }

    /// Mount `drive` from `host` at the conventional local path.
    /// Uses guest credentials — airlock is no-auth by design.
    func mount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        let mountPoint = mountPointFor(host: host, drive: drive)
        do {
            try FileManager.default.createDirectory(atPath: mountPoint,
                                                    withIntermediateDirectories: true)
        } catch {
            completion(error)
            return
        }
        let url = "//guest:@\(host.hostname)/\(drive.shareName)"
        run("/sbin/mount_smbfs", ["-N", url, mountPoint]) { [weak self] err in
            if err == nil {
                self?.mountPoints[self!.key(host: host, drive: drive)] = mountPoint
                self?.onChange?()
            }
            completion(err)
        }
    }

    /// Unmount `drive` from `host`. Best-effort — `umount` will fail
    /// if a Finder window is holding files open; we don't force.
    func unmount(host: HostState, drive: Drive, completion: @escaping (Error?) -> Void) {
        guard let mp = mountPoints[key(host: host, drive: drive)] else {
            completion(nil)
            return
        }
        run("/sbin/umount", [mp]) { [weak self] err in
            if err == nil {
                self?.mountPoints.removeValue(forKey: self!.key(host: host, drive: drive))
                _ = try? FileManager.default.removeItem(atPath: mp)
                self?.onChange?()
            }
            completion(err)
        }
    }

    /// Repopulate `mountPoints` from the current set of volumes.
    func refresh() {
        var next: [String: String] = [:]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                             options: []) ?? []
        for url in volumes {
            let path = url.path
            // Only paths that follow our naming convention. We can't
            // recover the original host / share reliably from the mount
            // point alone; parse them back out of the suffix.
            guard path.hasPrefix("/Volumes/"),
                  let idx = path.range(of: "-on-", options: .backwards) else {
                continue
            }
            let share = String(path[path.index(path.startIndex, offsetBy: "/Volumes/".count) ..< idx.lowerBound])
            let host = String(path[idx.upperBound ..< path.endIndex])
            next["\(host)/\(share)"] = path
        }
        mountPoints = next
    }

    private func key(host: HostState, drive: Drive) -> String {
        return "\(sanitize(host.hostname.replacingOccurrences(of: ".local", with: "")))/\(sanitize(drive.shareName))"
    }

    /// Lowercase alnum + dash/underscore; anything else becomes '-'.
    private func sanitize(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        for r in lower {
            if r.isLetter || r.isNumber || r == "-" || r == "_" {
                out.append(r)
            } else {
                out.append("-")
            }
        }
        // trim leading/trailing dashes
        while out.first == "-" { out.removeFirst() }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "airlock" : out
    }

    /// Wrapper over Process that fires `done` on the main queue.
    /// `done(nil)` means the process exited 0; otherwise carries an
    /// NSError with the stderr text as `localizedDescription`.
    private func run(_ launchPath: String, _ args: [String], done: @escaping (Error?) -> Void) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe() // discard
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
