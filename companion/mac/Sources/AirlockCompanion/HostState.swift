import Foundation

/// One discovered airlock host. Immutable identity (`serviceName`)
/// with a mutable endpoint (`hostname`, `port`) and observed state
/// (drives list, last error, last-seen timestamp). Main-actor only.
@MainActor
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
    /// Bumped whenever `stream` is replaced or stopped. Callbacks
    /// carry the generation they were created under and are dropped
    /// if it no longer matches — covers anything the old stream had
    /// already queued on main before `stop()` ran.
    private var streamGeneration = 0

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
    /// polling refresh. Called by Discovery on resolution; a no-op if
    /// a stream is already running (it reconnects on its own).
    func startEventStream() {
        guard stream == nil else { return }
        streamGeneration += 1
        let gen = streamGeneration
        let s = EventStream(
            url: baseURL.appendingPathComponent("api/events"),
            onDrives: { [weak self] drives in
                guard let self, self.streamGeneration == gen else { return }
                self.drives = drives
                self.isReachable = true
                self.lastSeenOnline = Date()
                self.lastError = nil
                self.onChange?()
            },
            onConnected: { [weak self] in
                guard let self, self.streamGeneration == gen else { return }
                self.isReachable = true
                self.lastError = nil
                self.lastSeenOnline = Date()
                self.onChange?()
            },
            onDisconnected: { [weak self] error in
                guard let self, self.streamGeneration == gen else { return }
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

    /// Stop the stream and mark the host offline. Clears `lastError`
    /// so the menu shows "offline · last seen …" rather than a stale
    /// transport error.
    func stopEventStream() {
        streamGeneration += 1
        stream?.stop()
        stream = nil
        let changed = isReachable || lastError != nil
        isReachable = false
        lastError = nil
        if changed { onChange?() }
    }

    /// Restore persisted state from disk (last-seen timestamp, cached
    /// drive list). Used by Discovery when replaying known hosts on
    /// startup before their SSE stream reconnects.
    func restore(lastSeen: Date?, cachedDrives: [Drive]) {
        self.lastSeenOnline = lastSeen
        self.drives = cachedDrives
        self.isReachable = false
    }

    /// Called when Bonjour re-resolves this host: hostname or port may
    /// have changed (Pi got a new DHCP lease, etc.). Idempotent — a
    /// running stream is only restarted when the endpoint actually
    /// moved, so per-address resolve callbacks (IPv4 + IPv6) don't
    /// cause reconnect storms.
    func updateEndpoint(hostname: String, port: Int) {
        guard hostname != self.hostname || port != self.port else { return }
        self.hostname = hostname
        self.port = port
        if stream != nil {
            stopEventStream()
            startEventStream()
        }
    }
}

/// Wire representation of a mounted drive — mirrors the JSON payload
/// airlockd's `internal/api/server.go` returns from `GET /api/drives`
/// and in `/api/events` `drives` events.
struct Drive: Codable, Equatable, Sendable {
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
    /// True while the daemon has withdrawn the SMB share and is
    /// unmounting. Absent from older daemons (and from drive lists
    /// cached by older companion builds) — defaults to false.
    let ejecting: Bool

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
        case ejecting
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareName   = try c.decode(String.self, forKey: .shareName)
        label       = try c.decode(String.self, forKey: .label)
        displayName = try c.decode(String.self, forKey: .displayName)
        fsType      = try c.decode(String.self, forKey: .fsType)
        sizeBytes   = try c.decode(Int64.self, forKey: .sizeBytes)
        sizeHuman   = try c.decode(String.self, forKey: .sizeHuman)
        readOnly    = try c.decode(Bool.self, forKey: .readOnly)
        mountPoint  = try c.decode(String.self, forKey: .mountPoint)
        kernel      = try c.decode(String.self, forKey: .kernel)
        parent      = try c.decode(String.self, forKey: .parent)
        ejecting    = try c.decodeIfPresent(Bool.self, forKey: .ejecting) ?? false
    }
}
