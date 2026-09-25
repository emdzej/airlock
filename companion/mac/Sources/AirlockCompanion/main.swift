import AppKit

// Top-level code runs on the main thread, but not every build path
// (SwiftPM native vs. XCBuild for universal builds) treats it as
// main-actor isolated — say so explicitly.
MainActor.assumeIsolated {
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
