import AppKit

/// Menu-bar shell. Owns the NSStatusItem, discovery, mount manager,
/// and action center; wires them together on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let discovery = Discovery()
    private let mounts = MountManager()
    private lazy var actions = ActionCenter(discovery: discovery, mounts: mounts)

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

        Notifier.shared.requestAuthorizationIfNeeded()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        MenuBuilder.build(into: menu, hosts: discovery.hosts,
                          mounts: mounts, actions: actions)
        statusItem.menu = menu
    }
}
