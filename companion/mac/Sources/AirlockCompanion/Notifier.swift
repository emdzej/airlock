import Foundation
import UserNotifications

/// Wraps macOS UserNotifications for the companion app. First call
/// prompts the user for permission; subsequent calls no-op silently
/// if the user denied.
final class Notifier {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    /// Ask for notification permission once and remember we did.
    /// Called from AppDelegate at startup.
    func requestAuthorizationIfNeeded() {
        guard !Preferences.shared.notificationsRequested else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Preferences.shared.notificationsRequested = true
        }
    }

    func info(_ title: String, body: String = "") {
        post(title: title, body: body)
    }

    func error(_ title: String, body: String) {
        post(title: title, body: body)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = nil // silent to start; too easy to be annoying otherwise
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }
}
