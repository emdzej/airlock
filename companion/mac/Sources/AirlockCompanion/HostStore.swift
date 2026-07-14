import Foundation

/// Persists the set of airlock hosts we've ever seen so they survive
/// across app restarts and brief network hiccups. On startup Discovery
/// preloads the store's entries as offline HostStates; when Bonjour
/// re-resolves them they flip back to online.
///
/// State is stored as a single JSON blob under UserDefaults key
/// `knownHosts`. Small: even a dozen airlocks with 4 drives each is
/// well under 4 KB.
final class HostStore {
    struct Persisted: Codable {
        let serviceName: String
        var hostname: String
        var port: Int
        var lastSeen: Date
        var cachedDrives: [Drive]
    }

    private let defaults = UserDefaults.standard
    private let key = "knownHosts"

    /// Prune hosts we haven't seen in more than this many days.
    /// Prevents the store from growing without bound as users test
    /// airlock instances on many networks.
    private let pruneAfter: TimeInterval = 30 * 24 * 3600

    static let shared = HostStore()

    func load() -> [Persisted] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Persisted].self, from: data)) ?? []
    }

    func save(_ items: [Persisted]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    /// Prune entries older than `pruneAfter` seconds. Called from
    /// AppDelegate on launch — cheap enough to run every start.
    func prune() {
        let cutoff = Date().addingTimeInterval(-pruneAfter)
        let kept = load().filter { $0.lastSeen >= cutoff || $0.lastSeen == .distantPast }
        save(kept)
    }
}
