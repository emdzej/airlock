import Foundation
import UserNotifications

/// Wraps macOS UserNotifications for the companion app. First call
/// prompts the user for permission; subsequent calls no-op silently
/// if the user denied.
///
/// UNUserNotificationCenter throws if the process has no bundle
/// (`swift run`), so in that case notifications are logged to stderr
/// instead.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    /// Ask for notification permission once and remember we did.
    /// Called from AppDelegate at startup.
    func requestAuthorizationIfNeeded() {
        guard let center, !Preferences.shared.notificationsRequested else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Preferences.shared.notificationsRequested = true }
            }
        }
    }

    func info(_ title: String, body: String = "") {
        post(title: title, body: body)
    }

    func error(_ title: String, body: String) {
        post(title: title, body: body)
    }

    private func post(title: String, body: String) {
        guard let center else {
            FileHandle.standardError.write(Data(
                "notify: \(title)\(body.isEmpty ? "" : " — \(body)")\n".utf8
            ))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = nil // silent to start; too easy to be annoying otherwise
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Without this, macOS suppresses banners while the app is
    /// frontmost — e.g. right after the user clicks a menu action or
    /// while the Preferences window is key.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
