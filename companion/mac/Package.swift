// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirlockCompanion",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AirlockCompanion",
            path: "Sources/AirlockCompanion"
        )
    ]
)
