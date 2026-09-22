// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiquidType",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LiquidType",
            path: "Sources/LiquidType",
            resources: [.copy("Resources/WebIcons")]
        ),
    ]
)
