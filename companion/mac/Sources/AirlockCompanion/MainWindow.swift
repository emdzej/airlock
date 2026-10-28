import AirlockKit
import AirlockUI
import AppKit
import SwiftUI

/// The full Airlock window — the same screens as the iOS app (drives,
/// devices, format, flash, dump, fsck, files, About). The app becomes a
/// regular one (Dock, ⌘-Tab) while the window is open and goes back to
/// menu-bar only when it closes.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let discovery: Discovery
    private var window: NSWindow?

    init(discovery: Discovery) {
        self.discovery = discovery
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = HostListView(discovery: discovery)
            .frame(minWidth: 760, minHeight: 520)
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        w.title = "Airlock"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        // The panes draw their own backgrounds (green sidebar, washed
        // detail) up to the top edge; an opaque title bar would add a
        // light strip that meets the sidebar in a corner.
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 980, height: 680))
        w.center()
        w.setFrameAutosaveName("AirlockMainWindow")
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

enum StatusIcon {
    /// The hatch as a menu-bar template image (18 pt, drawn at 2×).
    @MainActor
    static func make() -> NSImage? {
        let renderer = ImageRenderer(content:
            HatchView(lineWidth: 0.075)
                .foregroundStyle(.black)
                .frame(width: 18, height: 18)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Airlock"
        return image
    }
}
