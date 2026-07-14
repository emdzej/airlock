import AppKit

/// Renders the current discovery state into an NSMenu, wiring
/// selectors to methods on the shared ActionCenter.
enum MenuBuilder {

    // MARK: - Header composition

    private static func hostHeaderTitle(for host: HostState) -> NSAttributedString {
        // ● green  = live (isReachable && no error)
        // ● red    = last known state was an error
        // ● gray   = offline / not yet reachable
        let (dotColor, statusText): (NSColor, String)
        if let err = host.lastError, !host.isReachable {
            dotColor = .systemRed
            statusText = err
        } else if !host.isReachable {
            if let since = host.lastSeenOnline, since > .distantPast {
                dotColor = .secondaryLabelColor
                statusText = "offline · last seen \(relative(since))"
            } else {
                dotColor = .secondaryLabelColor
                statusText = "connecting…"
            }
        } else {
            dotColor = .systemGreen
            let n = host.drives.count
            statusText = "\(n) drive\(n == 1 ? "" : "s")"
        }
        let font = NSFont.menuBarFont(ofSize: 0)
        let base: [NSAttributedString.Key: Any] = [.font: font]

        let out = NSMutableAttributedString(string: "● ",
                                            attributes: base.merging(
                                                [.foregroundColor: dotColor],
                                                uniquingKeysWith: { $1 }
                                            ))
        out.append(NSAttributedString(
            string: host.serviceName,
            attributes: base
        ))
        out.append(NSAttributedString(
            string: "  " + statusText,
            attributes: base.merging(
                [.foregroundColor: NSColor.secondaryLabelColor],
                uniquingKeysWith: { $1 }
            )
        ))
        return out
    }

    /// Human relative string ("2 min ago", "3 h ago", "yesterday", …)
    /// for a past date. Uses a RelativeDateTimeFormatter so it matches
    /// the rest of macOS localization behavior for free.
    private static func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    static func build(into menu: NSMenu, hosts: [HostState],
                      mounts: MountManager, actions: ActionCenter) {
        if hosts.isEmpty {
            let empty = NSMenuItem(title: "Looking for airlock instances…",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (idx, host) in hosts.enumerated() {
                if idx > 0 { menu.addItem(NSMenuItem.separator()) }
                appendHost(host, mounts: mounts, actions: actions, to: menu)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(ActionCenter.openPreferences(_:)),
                               keyEquivalent: ",")
        prefs.target = actions
        menu.addItem(prefs)
        menu.addItem(NSMenuItem(title: "Quit Airlock Companion",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private static func appendHost(_ host: HostState, mounts: MountManager,
                                   actions: ActionCenter, to menu: NSMenu) {
        // Header line: colored status dot + host name + short status.
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = hostHeaderTitle(for: host)
        header.isEnabled = false
        menu.addItem(header)

        // Drives
        if host.drives.isEmpty && host.isReachable {
            let empty = NSMenuItem(title: "  no drives connected",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for drive in host.drives {
            let submenu = buildDriveSubmenu(host: host, drive: drive,
                                            mounts: mounts, actions: actions)
            let mounted = mounts.isMounted(host: host, drive: drive)
            let mark = mounted ? "✓ " : "   "
            let ro = drive.readOnly ? " · RO" : ""
            let title = "\(mark)\(drive.displayName) (\(drive.fsType), \(drive.sizeHuman))\(ro)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        // Host-level actions
        if host.isReachable {
            let hostCtx = HostContext(host: host)

            let ejectAll = NSMenuItem(title: "  Eject all drives on \(host.serviceName)",
                                      action: #selector(ActionCenter.ejectHost(_:)),
                                      keyEquivalent: "")
            ejectAll.target = actions
            ejectAll.representedObject = hostCtx
            ejectAll.isEnabled = !host.drives.isEmpty
            menu.addItem(ejectAll)

            let openWeb = NSMenuItem(title: "  Open web UI",
                                     action: #selector(ActionCenter.openWebUI(_:)),
                                     keyEquivalent: "")
            openWeb.target = actions
            openWeb.representedObject = hostCtx
            menu.addItem(openWeb)
        }
    }

    private static func buildDriveSubmenu(host: HostState, drive: Drive,
                                          mounts: MountManager,
                                          actions: ActionCenter) -> NSMenu {
        let sub = NSMenu()
        let ctx = DriveContext(host: host, drive: drive)
        let isMounted = mounts.isMounted(host: host, drive: drive)

        if isMounted {
            let unmount = NSMenuItem(title: "Unmount from this Mac",
                                     action: #selector(ActionCenter.unmountDrive(_:)),
                                     keyEquivalent: "")
            unmount.target = actions
            unmount.representedObject = ctx
            sub.addItem(unmount)

            let reveal = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(ActionCenter.revealDrive(_:)),
                                    keyEquivalent: "")
            reveal.target = actions
            reveal.representedObject = ctx
            sub.addItem(reveal)
        } else {
            let mount = NSMenuItem(title: "Mount on this Mac",
                                   action: #selector(ActionCenter.mountDrive(_:)),
                                   keyEquivalent: "")
            mount.target = actions
            mount.representedObject = ctx
            sub.addItem(mount)
        }

        let copyItem = NSMenuItem(title: "Copy SMB URL",
                                  action: #selector(ActionCenter.copySMBURL(_:)),
                                  keyEquivalent: "")
        copyItem.target = actions
        copyItem.representedObject = ctx
        sub.addItem(copyItem)

        sub.addItem(NSMenuItem.separator())

        let eject = NSMenuItem(title: "Eject drive from airlock",
                               action: #selector(ActionCenter.ejectDrive(_:)),
                               keyEquivalent: "")
        eject.target = actions
        eject.representedObject = ctx
        sub.addItem(eject)

        return sub
    }
}
