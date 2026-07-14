import Foundation

/// Browses the local network for `_airlock._tcp` advertisements and
/// keeps a list of hosts (currently-live + remembered-offline).
/// Each host has its own SSE-driven event stream via HostState.
final class Discovery: NSObject {
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private(set) var hosts: [HostState] = []

    /// Called whenever the host list or any host's drive list changes.
    /// Fires on the main queue — safe to touch UI directly.
    var onChange: (() -> Void)?

    private let store = HostStore.shared

    func start() {
        // Restore previously-seen hosts as offline placeholders — the
        // Bonjour resolve callback flips them back to live if the
        // service reappears.
        store.prune()
        for p in store.load() {
            let state = HostState(serviceName: p.serviceName, hostname: p.hostname, port: p.port)
            state.restore(lastSeen: p.lastSeen, cachedDrives: p.cachedDrives)
            state.onChange = { [weak self] in self?.persist(); self?.onChange?() }
            hosts.append(state)
        }
        persist()
        onChange?()

        browser.delegate = self
        browser.searchForServices(ofType: "_airlock._tcp.", inDomain: "local.")
    }

    private func persist() {
        let items = hosts.map { host in
            HostStore.Persisted(
                serviceName: host.serviceName,
                hostname: host.hostname,
                port: host.port,
                lastSeen: host.lastSeenOnline ?? .distantPast,
                cachedDrives: host.drives
            )
        }
        store.save(items)
    }
}

extension Discovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Mark the host as offline; don't drop from the list — it may
        // come back (Pi rebooted, briefly off Wi-Fi). Persistent store
        // (HostStore) prunes truly-gone hosts on its own schedule.
        if let host = hosts.first(where: { $0.serviceName == service.name }) {
            host.stopEventStream()
        }
        onChange?()
    }
}

extension Discovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ service: NetService) {
        pending.removeAll { $0 === service }
        guard let host = service.hostName else { return }
        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        let port = service.port > 0 ? service.port : 80
        if let existing = hosts.first(where: { $0.serviceName == service.name }) {
            // Persisted offline entry — refresh its hostname/port in
            // case the network moved the box, then reconnect.
            existing.updateEndpoint(hostname: hostname, port: port)
            existing.startEventStream()
            persist()
            onChange?()
            return
        }
        let state = HostState(serviceName: service.name, hostname: hostname, port: port)
        state.onChange = { [weak self] in self?.persist(); self?.onChange?() }
        hosts.append(state)
        state.startEventStream()
        persist()
        onChange?()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }
}
