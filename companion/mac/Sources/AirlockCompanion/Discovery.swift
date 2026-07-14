import Foundation

/// Browses the local network for `_airlock._tcp` advertisements and
/// keeps a list of resolved hosts. Each resolved host has its own
/// AirlockClient that polls `/api/drives`.
final class Discovery: NSObject {
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private(set) var hosts: [HostState] = []

    /// Called whenever the host list or any host's drive list changes.
    /// Fires on an arbitrary thread — dispatch to main before touching UI.
    var onChange: (() -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_airlock._tcp.", inDomain: "local.")
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
        // Bonjour hostnames come with a trailing dot; strip it so URLs
        // parse cleanly.
        let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
        let port = service.port > 0 ? service.port : 80
        // Reactivate a remembered host (persisted offline entry) if the
        // service name matches — that way its cached lastSeen /
        // rememberedHostname carry over.
        if let existing = hosts.first(where: { $0.serviceName == service.name }) {
            existing.startEventStream()
            onChange?()
            return
        }
        let state = HostState(serviceName: service.name, hostname: hostname, port: port)
        state.onChange = { [weak self] in self?.onChange?() }
        hosts.append(state)
        state.startEventStream()
        onChange?()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }
}
