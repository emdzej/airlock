import AirlockKit
import AliasSupport
import AliasSupportUI
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Report a Problem: ALIAS, an anonymous support desk. The app sends a
/// report only when the user writes one, with what they choose to keep
/// of a screenshot of the app's own window, the screen's name, the OS
/// and a few counts. No airlock names or addresses, no file names, no
/// account: the identity is an anonymous id made by the service and kept
/// in this device's Keychain.
public enum Support {
    static let url = URL(string: "https://help.getalias.support")!

    /// macOS: the login keychain. The data protection keychain needs a
    /// keychain entitlement, which the Developer ID DMG (no provisioning
    /// profile) can't have.
    static let store = KeychainIdentityStore(account: "airlock", dataProtection: Platform.isIOS)

    /// Nil when the build has no product key (Alias.local.xcconfig), and
    /// then Report a Problem isn't offered.
    public static let client: AliasClient? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "AliasProductKey") as? String,
              !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return AliasClient(
            url: url, key: key,
            store: store,
            appVersion: AppVersion.marketing,
            context: { Report.current.context },
            telemetry: { Report.current.telemetry })
    }()

    public static var isAvailable: Bool { client != nil }

    /// Whether this device has sent a report (has an anonymous id).
    static func hasIdentity() async -> Bool {
        (try? await store.load()) != nil
    }

    /// Deletes the reports and the anonymous id at the desk, and the id
    /// here. Without an id there's nothing to erase (and asking the
    /// service would make one first).
    static func erase() async throws -> Int {
        guard let client, await hasIdentity() else { return 0 }
        return try await client.eraseMe().tickets
    }

    static var labels: AliasLabels {
        var l = AliasLabels()
        l.reportTitle = "Report a Problem"
        l.yourReports = "Your Reports"
        return l
    }
}

/// What goes with the next report, set when Report a Problem is opened.
struct Report: Sendable {
    /// A screen's name ("Airlock", "Setup", "Mac menu"), not its content.
    var screen = ""
    var airlocks = 0
    var reachable = 0
    var demo = false

    var context: JSONObject {
        ["screen": .string(screen), "os": .string("\(Platform.osName) \(Platform.osVersion)")]
    }

    var telemetry: JSONObject {
        ["airlocks": .number(Double(airlocks)), "reachable": .number(Double(reachable)), "demo": .bool(demo)]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = Report()

    static var current: Report {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @MainActor
    init(screen: String, hosts: [HostState]) {
        self.screen = screen
        airlocks = hosts.filter { !$0.isDemo }.count
        reachable = hosts.filter { !$0.isDemo && $0.isReachable }.count
        demo = hosts.contains { $0.isDemo }
    }

    init() {}
}

/// The report, the user's reports and support's answers.
struct ReportProblemSheet: View {
    let client: AliasClient
    let screenshot: CGImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AliasReportView(client: client, screenshot: screenshot, labels: Support.labels)
                .formStyle(.grouped)
                .scrollDismissesKeyboard(.interactively)
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(Support.labels.yourReports) {
                            AliasTicketsView(client: client, labels: Support.labels)
                        }
                    }
                    #if os(iOS)
                    // Return types a new line in the note: a way out of
                    // the keyboard.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                        }
                    }
                    #endif
                }
        }
        .sheetFrame(width: 520, height: 640)
        .modifier(AppKitScenePhase())
    }
}

/// The ALIAS thread loads and listens only while the scene phase is
/// active. The Mac window is AppKit's (an NSHostingController, no
/// SwiftUI scene), where the phase never says so: give it the app's.
private struct AppKitScenePhase: ViewModifier {
    #if os(macOS)
    @State private var active = NSApp.isActive

    func body(content: Content) -> some View {
        content
            .environment(\.scenePhase, active ? .active : .background)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

extension View {
    /// Presents Report a Problem when `request` is set: the screenshot is
    /// taken first, of the app's own window as it is, before the sheet
    /// covers it.
    func reportProblemSheet(_ request: Binding<Report?>) -> some View {
        modifier(ReportProblemPresenter(request: request))
    }
}

private struct ReportProblemPresenter: ViewModifier {
    @Binding var request: Report?
    @State private var shown: Shot?

    /// The sheet's payload: with sheet(item:) the content gets the
    /// screenshot it was opened with, never a stale one.
    struct Shot: Identifiable {
        let id = UUID()
        let image: CGImage?
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request != nil) { _, asked in
                guard asked, let request, Support.client != nil else { return }
                Report.current = request
                Task {
                    // Let the menu that asked finish closing first.
                    try? await Task.sleep(for: .milliseconds(350))
                    shown = Shot(image: WindowShot.capture())
                }
            }
            .sheet(item: $shown, onDismiss: { request = nil }) { shot in
                if let client = Support.client {
                    ReportProblemSheet(client: client, screenshot: shot.image)
                }
            }
    }
}

/// The app's own key window, drawn by the app: never the rest of the
/// screen, and no screen-recording permission involved.
@MainActor
enum WindowShot {
    static func capture() -> CGImage? {
        #if os(iOS)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow
        else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }.cgImage
        #else
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        // The frame view: the content and the title bar.
        guard let window, let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let drawn = rep.cgImage else { return nil }
        // Vibrant areas (the sidebar) come out transparent, and a JPEG
        // would make them black, as if blacked out: lay the shot on the
        // window's background colour.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return drawn }
        let rect = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
        var background = NSColor.windowBackgroundColor.cgColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(drawn, in: rect)
        return ctx.makeImage() ?? drawn
        #endif
    }
}

extension Notification.Name {
    /// The Mac's Help › Report a Problem… and the menu-bar item: the
    /// window opens and shows the report.
    public static let airlockReportProblem = Notification.Name("airlockReportProblem")
}
