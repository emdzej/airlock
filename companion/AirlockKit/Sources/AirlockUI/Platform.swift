import AirlockKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The few places iOS and macOS differ, so the views themselves stay
// shared between the iOS app and the Mac companion's window.

extension Color {
    /// Airlock green, from the app icon: darker in light mode, brighter
    /// in dark mode. Used instead of the accent colour so the Mac
    /// companion (no asset catalog) matches the iOS app.
    static let brand = Color(light: (0x2E, 0x8A, 0x62), dark: (0x4C, 0xC3, 0x8F))

    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private init(light: (Int, Int, Int), dark: (Int, Int, Int)) {
        func rgb(_ c: (Int, Int, Int)) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat(c.0) / 255, CGFloat(c.1) / 255, CGFloat(c.2) / 255)
        }
        let (l, d) = (rgb(light), rgb(dark))
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? d : l
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = dark ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

enum Platform {
    static var osName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        "macOS"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var devices: String {
        #if os(iOS)
        "iPhone and iPad"
        #else
        "your Mac"
        #endif
    }
}

/// Keeps a long operation alive: on iOS the screen stays on and the app
/// asks for background time; on macOS idle sleep is held off.
@MainActor
final class KeepAwake {
    #if os(iOS)
    private var task = UIBackgroundTaskIdentifier.invalid
    #else
    private var activity: NSObjectProtocol?
    #endif

    init(_ reason: String) {
        Activity.shared.begin()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        task = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        #else
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        #endif
    }

    func end() {
        Activity.shared.end()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        #else
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        task = .invalid
    }
    #endif
}

extension Notification.Name {
    /// Reload what isn't live (device list, open folder): posted by the
    /// Mac companion's View › Refresh (⌘R).
    public static let airlockRefresh = Notification.Name("pl.emdzej.airlock.refresh")
}

extension ToolbarItemPlacement {
    /// The trailing edge on both platforms: `.primaryAction` is trailing
    /// on iOS but leading or centred in a Mac window's toolbar.
    static var trailingAction: ToolbarItemPlacement {
        #if os(iOS)
        .primaryAction
        #else
        .automatic
        #endif
    }
}

extension ScenePhase {
    /// Whether to keep polling. The Mac companion hosts these views in
    /// an AppKit window, which never reports a SwiftUI scene phase, so
    /// it counts as always active there.
    var isForeground: Bool {
        #if os(iOS)
        self == .active
        #else
        true
        #endif
    }
}

extension View {
    /// macOS sizes sheets to their content, and lists and forms have
    /// none: give them a usable size there.
    func sheetFrame(width: CGFloat = 520, height: CGFloat = 600) -> some View {
        #if os(iOS)
        self
        #else
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #endif
    }

    /// macOS shows no back button for screens pushed onto the split
    /// view's detail stack, so pushed screens add their own (⌘[).
    func macBackButton() -> some View {
        modifier(MacBackButton())
    }

    /// macOS: let the pane's background run under the window toolbar,
    /// instead of a separate light strip that meets the sidebar in a
    /// corner.
    func macTransparentToolbar() -> some View {
        #if os(macOS)
        toolbarBackground(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }

    /// Compact navigation titles on iOS; macOS has only one kind.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Volume labels are conventionally upper case.
    func capitalizedInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    func plainInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

private struct MacBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(macOS)
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            }
        }
        #else
        content
        #endif
    }
}
