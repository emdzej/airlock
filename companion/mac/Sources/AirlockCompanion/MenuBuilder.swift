import AppKit

/// Renders the current discovery state into an NSMenu.
enum MenuBuilder {
    static func build(into menu: NSMenu, hosts: [HostState]) {
        if hosts.isEmpty {
            let empty = NSMenuItem(title: "Looking for airlock instances…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (idx, host) in hosts.enumerated() {
                if idx > 0 { menu.addItem(NSMenuItem.separator()) }
                appendHost(host, to: menu)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Airlock Companion",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    private static func appendHost(_ host: HostState, to menu: NSMenu) {
        let count = host.drives.count
        let title: String
        if let err = host.lastError {
            title = "\(host.serviceName) — \(err)"
        } else if !host.isReachable {
            title = "\(host.serviceName) — connecting…"
        } else {
            title = "\(host.serviceName) — \(count) drive\(count == 1 ? "" : "s")"
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if host.drives.isEmpty && host.isReachable {
            let empty = NSMenuItem(title: "  no drives connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for drive in host.drives {
            let ro = drive.readOnly ? " · read-only" : ""
            let item = NSMenuItem(
                title: "  \(drive.displayName) (\(drive.fsType), \(drive.sizeHuman))\(ro)",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
    }
}
