// swift-tools-version:5.9
import PackageDescription

// Shared by the macOS and iOS companions: wire models, the airlockd HTTP
// client, the /api/events SSE reader, Bonjour discovery and the
// remembered-hosts store. No UI.
let package = Package(
    name: "AirlockKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "AirlockKit", targets: ["AirlockKit"])
    ],
    targets: [
        .target(name: "AirlockKit"),
        .testTarget(name: "AirlockKitTests", dependencies: ["AirlockKit"])
    ]
)
