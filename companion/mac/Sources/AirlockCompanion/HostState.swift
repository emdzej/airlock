import Foundation

/// One discovered airlock host. Immutable identity (`serviceName`,
/// `hostname`, `port`) with mutable observed state (drives list,
/// last error, last-seen timestamp). Not thread-safe by design —
/// callers mutate on the main queue.
final class HostState {
    let serviceName: String
    private(set) var hostname: String
    private(set) var port: Int

    private(set) var drives: [Drive] = []
    private(set) var lastError: String?
    private(set) var isReachable: Bool = false
    private(set) var lastSeenOnline: Date?

    /// Fires whenever any observed property changes (drives / error /
    /// reachability). Assign in the owner (Discovery) so it can rebuild
    /// the menu.
    var onChange: (() -> Void)?

    private var stream: EventStream?

    init(serviceName: String, hostname: String, port: Int) {
        self.serviceName = serviceName
        self.hostname = hostname
        self.port = port
    }

    var baseURL: URL {
        URL(string: "http://\(hostname):\(port)")!
    }

    /// Open the live SSE stream. The daemon sends the current drive
    /// list immediately on connect, so this replaces the previous
    /// polling refresh. Called by Discovery on resolution.
    func startEventStream() {
        stream?.stop()
        let s = EventStream(
            url: baseURL.appendingPathComponent("api/events"),
            onDrives: { [weak self] drives in
                guard let self else { return }
                self.drives = drives
                self.isReachable = true
                self.lastSeenOnline = Date()
                self.lastError = nil
                self.onChange?()
            },
            onConnected: { [weak self] in
                guard let self else { return }
                self.isReachable = true
                self.lastError = nil
                self.lastSeenOnline = Date()
                self.onChange?()
            },
            onDisconnected: { [weak self] error in
                guard let self else { return }
                self.isReachable = false
                if let e = error {
                    self.lastError = e.localizedDescription
                }
                self.onChange?()
            }
        )
        stream = s
        s.start()
    }

    func stopEventStream() {
        stream?.stop()
        stream = nil
    }

    /// Restore persisted state from disk (last-seen timestamp, cached
    /// drive list). Used by HostStore when replaying known hosts on
    /// startup before their SSE stream reconnects.
    func restore(lastSeen: Date?, cachedDrives: [Drive]) {
        self.lastSeenOnline = lastSeen
        self.drives = cachedDrives
        self.isReachable = false
    }

    /// Called when Bonjour re-resolves this host: hostname or port may
    /// have changed (Pi got a new DHCP lease, etc.). Idempotent.
    func updateEndpoint(hostname: String, port: Int) {
        self.hostname = hostname
        self.port = port
    }
}

/// Wire representation of a mounted drive — mirrors the JSON payload
/// airlockd's `internal/api/server.go` returns from `GET /api/drives`.
struct Drive: Codable, Equatable {
    let shareName: String
    let label: String
    let displayName: String
    let fsType: String
    let sizeBytes: Int64
    let sizeHuman: String
    let readOnly: Bool
    let mountPoint: String
    let kernel: String
    let parent: String

    enum CodingKeys: String, CodingKey {
        case shareName   = "share_name"
        case label
        case displayName = "display_name"
        case fsType      = "fs_type"
        case sizeBytes   = "size_bytes"
        case sizeHuman   = "size_human"
        case readOnly    = "read_only"
        case mountPoint  = "mount_point"
        case kernel
        case parent
    }
}
