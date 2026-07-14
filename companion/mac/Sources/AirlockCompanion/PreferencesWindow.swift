import AppKit
import SwiftUI

/// Preferences window controller. Kept trivially small: one toggle
/// for auto-mount. Persisted through @AppStorage so the UI stays in
/// sync with any other reader of the same defaults key.
final class PreferencesWindowController {
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Airlock Companion"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PreferencesView: View {
    @AppStorage("autoMountAll") private var autoMountAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Auto-mount all discovered drives", isOn: $autoMountAll)
                .toggleStyle(.checkbox)
                .font(.body)
            Text("When enabled, every drive that appears on any airlock on your local network is automatically mounted on this Mac. Mount points follow the pattern /Volumes/<share>-on-<host>.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
    }
}
