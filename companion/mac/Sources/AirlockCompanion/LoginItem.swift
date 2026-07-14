import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+). Lets the
/// preferences window toggle "open at login" without pulling
/// ServiceManagement into every file that touches preferences.
enum LoginItem {
    /// True iff we're currently registered to launch at login.
    static var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// True when the user has granted us login-item approval (or hasn't
    /// been asked). False when macOS is showing a "requires approval"
    /// system prompt for our app.
    static var isApproved: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .notRegistered, .notFound:
            return true
        case .requiresApproval:
            return false
        @unknown default:
            return true
        }
    }

    /// Idempotent: registering when already enabled is a no-op.
    /// Throws on macOS-side failure — the caller (preferences UI)
    /// surfaces the error to the user.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
