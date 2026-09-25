import Foundation

/// Browses the local network for `_airlock._tcp` advertisements and
/// keeps a list of hosts (currently-live + remembered-offline).
/// Each host has its own SSE-driven event stream via HostState.
///
/// Hosts are keyed by Bonjour service name. That's unique on a LAN:
/// the Pi advertises via Avahi, which renames on conflict
/// ("airlock #2"), so two boxes with the same hostname still show
/// up as distinct services.
@MainActor
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

    private func found(_ service: NetService) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    private func removed(name: String) {
        // Mark the host as offline; don't drop from the list — it may
        // come back (Pi rebooted, briefly off Wi-Fi). HostStore prunes
        // truly-gone hosts on the next launch.
        if let host = hosts.first(where: { $0.serviceName == name }) {
            host.stopEventStream()
        }
        onChange?()
    }

    private func resolved(_ service: NetService) {
        pending.removeAll { $0 === service }
        guard let host = service.hostName else { return }
        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        let port = service.port > 0 ? service.port : 80
        if let existing = hosts.first(where: { $0.serviceName == service.name }) {
            // Persisted offline entry or a repeat resolve — refresh
            // hostname/port in case the network moved the box. Both
            // calls are no-ops when nothing changed / already live.
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

    private func failedToResolve(_ service: NetService) {
        pending.removeAll { $0 === service }
    }
}

// NetService delivers callbacks on the run loop it was scheduled on —
// the main one, since start() runs on main — so hopping into the main
// actor synchronously is safe. NetService isn't Sendable; the
// nonisolated(unsafe) rebinding tells the checker we never leave main.
extension Discovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { found(service) }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        MainActor.assumeIsolated { removed(name: name) }
    }
}

extension Discovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { resolved(service) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        nonisolated(unsafe) let sender = sender
        MainActor.assumeIsolated { failedToResolve(sender) }
    }
}
