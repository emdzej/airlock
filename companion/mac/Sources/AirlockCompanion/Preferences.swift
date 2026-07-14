import Foundation

/// Thin wrapper over UserDefaults for the app's preferences. Keeps
/// the keys in one place and gives us a spot to add validation later.
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    /// When true, every drive that appears on any discovered airlock
    /// is auto-mounted on this Mac. Off by default.
    var autoMountAll: Bool {
        get { defaults.bool(forKey: Key.autoMountAll) }
        set { defaults.set(newValue, forKey: Key.autoMountAll) }
    }

    /// Notification consent flag we set once the user has been asked
    /// (regardless of allow/deny). Prevents re-prompting on every launch.
    var notificationsRequested: Bool {
        get { defaults.bool(forKey: Key.notificationsRequested) }
        set { defaults.set(newValue, forKey: Key.notificationsRequested) }
    }

    private enum Key {
        static let autoMountAll = "autoMountAll"
        static let notificationsRequested = "notificationsRequested"
    }
}
