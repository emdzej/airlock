import Foundation

/// One discovered airlock host. Immutable identity (`serviceName`)
/// with a mutable endpoint (`hostname`, `port`) and observed state
/// (drives list, last error, last-seen timestamp). Main-actor only.
@MainActor
public final class HostState: ObservableObject, Identifiable {
    public let serviceName: String
    @Published public private(set) var hostname: String
    @Published public private(set) var port: Int

    @Published public private(set) var drives: [Drive] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isReachable: Bool = false
    @Published public private(set) var lastSeenOnline: Date?

    public nonisolated var id: String { serviceName }

    /// Fires whenever any observed property changes (drives / error /
    /// reachability). Assign in the owner (Discovery) so it can rebuild
    /// the menu.
    public var onChange: (() -> Void)?

    private var stream: EventStream?
    /// Bumped whenever `stream` is replaced or stopped. Callbacks
    /// carry the generation they were created under and are dropped
    /// if it no longer matches — covers anything the old stream had
    /// already queued on main before `stop()` ran.
    private var streamGeneration = 0

    public init(serviceName: String, hostname: String, port: Int) {
        self.serviceName = serviceName
        self.hostname = hostname
        self.port = port
    }

    /// The in-app demo airlock (DemoAirlock), not a device.
    public var isDemo: Bool { hostname == DemoAirlock.hostname }

    public var baseURL: URL {
        URL(string: "http://\(hostname):\(port)")!
    }

    /// Open the live SSE stream. The daemon sends the current drive
    /// list immediately on connect, so this replaces the previous
    /// polling refresh. Called by Discovery on resolution; a no-op if
    /// a stream is already running (it reconnects on its own).
    public func startEventStream() {
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
    public func stopEventStream() {
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
    public func restore(lastSeen: Date?, cachedDrives: [Drive]) {
        self.lastSeenOnline = lastSeen
        self.drives = cachedDrives
        self.isReachable = false
    }

    /// Called when Bonjour re-resolves this host: hostname or port may
    /// have changed (Pi got a new DHCP lease, etc.). Idempotent — a
    /// running stream is only restarted when the endpoint actually
    /// moved, so per-address resolve callbacks (IPv4 + IPv6) don't
    /// cause reconnect storms.
    public func updateEndpoint(hostname: String, port: Int) {
        guard hostname != self.hostname || port != self.port else { return }
        self.hostname = hostname
        self.port = port
        if stream != nil {
            stopEventStream()
            startEventStream()
        }
    }
}
