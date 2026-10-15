// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DynamicMacNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DynamicMacNotch",
            path: "Sources/DynamicMacNotch"
        )
    ]
)
