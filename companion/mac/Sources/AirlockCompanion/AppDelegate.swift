import AppKit
import AirlockKit

/// Menu-bar shell. Owns the NSStatusItem, discovery, mount manager,
/// and action center; wires them together on launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let discovery = Discovery()
    private let mounts = MountManager()
    private lazy var actions = ActionCenter(discovery: discovery, mounts: mounts)
    private var changePending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.make() ?? NSImage(
                systemSymbolName: "externaldrive.badge.wifi",
                accessibilityDescription: "Airlock"
            )
            button.image?.isTemplate = true
        }
        rebuildMenu()

        // Rebuild the menu whenever discovery / local mounts change.
        // Order: (1) reconcile ejected drives (unmount stale locals),
        // then (2) auto-mount any newly-appeared drives, then (3)
        // rebuild the menu with the final state. Deferred to the next
        // main-queue turn and coalesced, so a burst of changes (and
        // changes caused by the steps themselves) runs this once.
        let onChange: () -> Void = { [weak self] in
            guard let self, !self.changePending else { return }
            self.changePending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.changePending = false
                    self.actions.reconcileEjected()
                    self.actions.maybeAutoMount()
                    self.rebuildMenu()
                }
            }
        }
        discovery.onChange = onChange
        mounts.onChange = onChange

        discovery.start()

        Notifier.shared.requestAuthorizationIfNeeded()

        // First launch: open the window, so the setup steps (no airlock
        // yet) and the full feature set aren't hidden behind the menu.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "launchedBefore") || CommandLine.arguments.contains("--open-window") {
            defaults.set(true, forKey: "launchedBefore")
            actions.mainWindow.show()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        MenuBuilder.build(into: menu, hosts: discovery.hosts,
                          mounts: mounts, actions: actions)
        statusItem.menu = menu
    }
}
