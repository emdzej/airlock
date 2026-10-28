// swift-tools-version:5.9
import PackageDescription

// Shared by the macOS and iOS companions.
// AirlockKit: wire models, the airlockd HTTP client, the /api/events SSE
// reader, Bonjour discovery and the remembered-hosts store. No UI.
// AirlockUI: the SwiftUI screens (drives, devices, operations, files,
// About), used by the iOS app and the Mac companion's window.
let package = Package(
    name: "AirlockKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AirlockKit", targets: ["AirlockKit"]),
        .library(name: "AirlockUI", targets: ["AirlockUI"])
    ],
    targets: [
        .target(name: "AirlockKit"),
        .target(name: "AirlockUI", dependencies: ["AirlockKit"]),
        .testTarget(name: "AirlockKitTests", dependencies: ["AirlockKit"])
    ]
)
