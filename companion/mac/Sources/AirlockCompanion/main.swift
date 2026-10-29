import AppKit

// Top-level code runs on the main thread, but not every build path
// (SwiftPM native vs. XCBuild for universal builds) treats it as
// main-actor isolated — say so explicitly.
MainActor.assumeIsolated {
    migrateLegacyDefaults()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Belt-and-suspenders: LSUIElement=YES in Info.plist keeps us out of
    // the Dock, and .accessory activation policy at runtime enforces the
    // same when launched via `swift run` without a bundle.
    app.setActivationPolicy(.accessory)

    // NSApplication.delegate is weak; keep ours alive for the run loop.
    withExtendedLifetime(delegate) { app.run() }
}

/// Up to 0.5.0 the bundle id was com.emdzej.airlock.companion. Copy its
/// preferences (remembered airlocks, settings) into the new domain once.
@MainActor
func migrateLegacyDefaults() {
    let legacy = "com.emdzej.airlock.companion"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
    defaults.set(true, forKey: "migratedLegacyDefaults")
    guard let old = defaults.persistentDomain(forName: legacy) else { return }
    for (key, value) in old where defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
    }
}
