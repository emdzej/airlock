import FileProvider
import Foundation

/// Stable item identifiers for a path-addressed API. Files expects an
/// item to keep its identifier across renames and moves; airlockd only
/// knows paths. Each path seen gets a UUID, renames rewrite the paths
/// under it, and the map is saved in the extension's container so
/// identifiers survive the extension being relaunched.
final class ItemMap: @unchecked Sendable {
    private var pathByID: [String: String] = [:]
    private var idByPath: [String: String] = [:]
    private let lock = NSLock()
    private let file: URL

    init(domain: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ItemMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = domain.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "domain"
        file = base.appendingPathComponent(safe + ".json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            pathByID = saved
            for (id, path) in saved { idByPath[path] = id }
        }
    }

    /// "/" for the root container, nil for an identifier we don't know
    /// (or the trash and working set, which have no path).
    func path(for id: NSFileProviderItemIdentifier) -> String? {
        if id == .rootContainer { return "/" }
        lock.lock(); defer { lock.unlock() }
        return pathByID[id.rawValue]
    }

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        if path == "/" { return .rootContainer }
        lock.lock(); defer { lock.unlock() }
        if let id = idByPath[path] { return NSFileProviderItemIdentifier(id) }
        let id = UUID().uuidString
        idByPath[path] = id
        pathByID[id] = path
        saveLocked()
        return NSFileProviderItemIdentifier(id)
    }

    /// After a rename or move: the item and everything under it.
    func move(from old: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        for (path, id) in idByPath where path == old || path.hasPrefix(old + "/") {
            let moved = new + path.dropFirst(old.count)
            idByPath[path] = nil
            idByPath[moved] = id
            pathByID[id] = moved
        }
        saveLocked()
    }

    func remove(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        for (p, id) in idByPath where p == path || p.hasPrefix(path + "/") {
            idByPath[p] = nil
            pathByID[id] = nil
        }
        saveLocked()
    }

    private func saveLocked() {
        if let data = try? JSONEncoder().encode(pathByID) {
            try? data.write(to: file, options: .atomic)
        }
    }
}

func joinPath(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

func parentPath(_ path: String) -> String {
    let p = (path as NSString).deletingLastPathComponent
    return p.isEmpty ? "/" : p
}
