import AppKit

/// Menu-bar shell. Owns the NSStatusItem, discovery, mount manager,
/// and action center; wires them together on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let discovery = Discovery()
    private let mounts = MountManager()
    private lazy var actions = ActionCenter(discovery: discovery, mounts: mounts)
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "externaldrive.badge.wifi",
                accessibilityDescription: "Airlock"
            )
            button.image?.isTemplate = true
        }
        rebuildMenu()

        // Rebuild the menu whenever discovery / local mounts change.
        let onChange: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.actions.maybeAutoMount()
                self?.rebuildMenu()
            }
        }
        discovery.onChange = onChange
        mounts.onChange = onChange

        discovery.start()

        // Poll each host's /api/drives every 3 s so remote drive
        // changes reach the menu without the user clicking.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.discovery.refreshAllDrives()
        }

        Notifier.shared.requestAuthorizationIfNeeded()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        MenuBuilder.build(into: menu, hosts: discovery.hosts,
                          mounts: mounts, actions: actions)
        statusItem.menu = menu
    }
}
