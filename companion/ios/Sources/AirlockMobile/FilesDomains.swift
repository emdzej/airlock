import AirlockKit
import FileProvider
import os

/// Keeps one Files location (File Provider domain) per shared drive.
/// A drive's domain is added when a reachable host shares it and removed
/// once that host is reachable and no longer shares it. Domains of
/// offline hosts stay: the host may be back in a minute, and Files shows
/// them as unreachable meanwhile.
@MainActor
final class FilesDomains {
    private let log = Logger(subsystem: "pl.emdzej.airlock.companion", category: "files-domains")
    private var running = false
    private var pending: [HostState]?

    func update(_ hosts: [HostState]) {
        pending = hosts
        guard !running else { return }
        running = true
        Task {
            while let hosts = pending {
                pending = nil
                await reconcile(hosts)
            }
            running = false
        }
    }

    private func reconcile(_ hosts: [HostState]) async {
        let multipleHosts = hosts.count > 1
        var wanted: [String: String] = [:] // domain id → display name
        var authoritative = Set<String>()  // hostnames whose drive list is current
        for host in hosts where host.isReachable {
            authoritative.insert(host.hostname)
            for drive in host.drives where !drive.ejecting {
                let id = DriveDomainID(hostname: host.hostname, port: host.port, share: drive.shareName)
                wanted[id.rawValue] = multipleHosts ? "\(drive.displayName) (\(host.hostname))" : drive.displayName
            }
        }
        let known = Set(hosts.map(\.hostname))

        let existing: [NSFileProviderDomain]
        do {
            existing = try await NSFileProviderManager.domains()
        } catch {
            log.error("listing domains: \(error.localizedDescription, privacy: .public)")
            return
        }

        for domain in existing {
            let raw = domain.identifier.rawValue
            guard let id = DriveDomainID(raw) else { continue }
            let stale = authoritative.contains(id.hostname) && wanted[raw] == nil
            let forgotten = !known.contains(id.hostname)
            if stale || forgotten {
                do { try await NSFileProviderManager.remove(domain) }
                catch { log.error("removing \(raw, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            } else {
                if let name = wanted[raw], name == domain.displayName {
                    wanted[raw] = nil // already there
                }
                // The airlock is reachable again: clear a "server
                // unreachable" the extension reported while it wasn't,
                // or Files keeps a sync-problem badge on the app.
                if authoritative.contains(id.hostname) {
                    try? await NSFileProviderManager(for: domain)?
                        .signalErrorResolved(NSFileProviderError(.serverUnreachable))
                }
            }
        }

        // New drives, and renamed ones (re-adding updates the display name).
        for (raw, name) in wanted {
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(raw), displayName: name)
            do { try await NSFileProviderManager.add(domain) }
            catch { log.error("adding \(raw, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }
}
