import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Belt-and-suspenders: LSUIElement=YES in Info.plist keeps us out of
// the Dock, and .accessory activation policy at runtime enforces the
// same when launched via `swift run` without a bundle.
app.setActivationPolicy(.accessory)

app.run()
