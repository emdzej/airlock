import AppKit

/// Menu-bar shell. Owns the NSStatusItem, drives discovery, and
/// rebuilds the menu whenever the discovered set of hosts (or their
/// drive lists) changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let discovery = Discovery()
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // externaldrive.badge.wifi is available macOS 12+ — perfect
            // metaphor: a drive accessible over the network.
            button.image = NSImage(
                systemSymbolName: "externaldrive.badge.wifi",
                accessibilityDescription: "Airlock"
            )
            button.image?.isTemplate = true
        }
        rebuildMenu()

        discovery.onChange = { [weak self] in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
        discovery.start()

        // Poll each known host's /api/drives every 3 s so the drive
        // list stays fresh even when the mDNS view is unchanged.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.discovery.refreshAllDrives()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        MenuBuilder.build(into: menu, hosts: discovery.hosts)
        statusItem.menu = menu
    }
}
