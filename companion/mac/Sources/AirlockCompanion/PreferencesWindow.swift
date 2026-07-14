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
    @AppStorage("openOnMount") private var openOnMount = false
    @State private var loginItemEnabled: Bool = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto-mount all discovered drives", isOn: $autoMountAll)
                    .toggleStyle(.checkbox)
                Text("Every drive that appears on any airlock on your local network is automatically mounted on this Mac.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Open in Finder after mounting", isOn: $openOnMount)
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
                Text("Reveal the drive in Finder as soon as it mounts (either from the menu's Mount action or the auto-mount above).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginItemEnabled = LoginItem.isEnabled
                            loginItemError = LoginItem.isApproved
                                ? nil
                                : "Approval pending — enable in System Settings → Login Items."
                        } catch {
                            loginItemError = error.localizedDescription
                            loginItemEnabled = LoginItem.isEnabled
                        }
                    }
                )).toggleStyle(.checkbox)
                if let err = loginItemError {
                    Text(err)
                        .font(.callout)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Airlock Companion launches automatically when you log in.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
