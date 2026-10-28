// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirlockCompanion",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../AirlockKit")
    ],
    targets: [
        .executableTarget(
            name: "AirlockCompanion",
            dependencies: [
                .product(name: "AirlockKit", package: "AirlockKit"),
                .product(name: "AirlockUI", package: "AirlockKit"),
            ],
            path: "Sources/AirlockCompanion",
            linkerSettings: [
                // NetFSMountURLSync (used for silent SMB mount).
                .linkedFramework("NetFS")
            ]
        )
    ]
)
