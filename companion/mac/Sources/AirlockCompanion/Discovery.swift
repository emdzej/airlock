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

    func refreshAllDrives() {
        for host in hosts {
            host.refresh { [weak self] in self?.onChange?() }
        }
    }
}

extension Discovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pending.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        hosts.removeAll { $0.serviceName == service.name }
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
        // Guard against duplicates (multi-interface Macs can resolve
        // the same service twice; we key by service instance name).
        if hosts.contains(where: { $0.serviceName == service.name }) { return }
        let state = HostState(serviceName: service.name, hostname: hostname, port: port)
        hosts.append(state)
        state.refresh { [weak self] in self?.onChange?() }
        onChange?()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }
}
