// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirlockCompanion",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../AirlockKit")
    ],
    targets: [
        .executableTarget(
            name: "AirlockCompanion",
            dependencies: ["AirlockKit"],
            path: "Sources/AirlockCompanion",
            linkerSettings: [
                // NetFSMountURLSync (used for silent SMB mount).
                .linkedFramework("NetFS")
            ]
        )
    ]
)
