import AirlockUI
import AppKit

/// The app's main menu. A menu-bar-only app never shows it, but its key
/// equivalents are what make ⌘Q, ⌘W, ⌘M, ⌘C/⌘V and friends work in the
/// Airlock and Preferences windows. Standard items target the first
/// responder (nil target), so AppKit routes them to the key window.
@MainActor
enum MainMenu {
    static func install(actions: ActionCenter) {
        let main = NSMenu()
        main.addItem(submenu(appMenu(actions: actions)))
        main.addItem(submenu(fileMenu(actions: actions)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(windowMenu()))
        main.addItem(submenu(helpMenu(actions: actions)))
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = main.item(withTitle: "Help")?.submenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.target = target
        return i
    }

    private static func appMenu(actions: ActionCenter) -> NSMenu {
        let m = NSMenu(title: "Airlock Companion")
        m.addItem(item("About Airlock Companion", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(ActionCenter.openPreferences(_:)), ",", target: actions))
        m.addItem(.separator())
        m.addItem(item("Hide Airlock Companion", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit Airlock Companion", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(actions: ActionCenter) -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(item("Open Airlock…", #selector(ActionCenter.openMainWindow(_:)), "o", target: actions))
        m.addItem(.separator())
        m.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Delete", #selector(NSText.delete(_:))))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        // AppKit appends Emoji & Symbols (⌃⌘Space) and Dictation to a
        // menu titled "Edit".
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Refresh", #selector(MenuActions.refresh(_:)), "r", target: MenuActions.shared))
        m.addItem(.separator())
        m.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    private static func helpMenu(actions: ActionCenter) -> NSMenu {
        let m = NSMenu(title: "Help")
        m.addItem(item("Airlock User Guide", #selector(MenuActions.openGuide(_:)), "?", target: MenuActions.shared))
        return m
    }
}

/// Targets for main-menu items that aren't standard responder actions.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    /// Devices and file lists reload; drives are live already.
    @objc func refresh(_ sender: Any?) {
        NotificationCenter.default.post(name: .airlockRefresh, object: nil)
    }

    @objc func openGuide(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://airlock.emdzej.pl/guide")!)
    }
}
