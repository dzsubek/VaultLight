// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaultLightCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaultLightCore", targets: ["VaultLightCore"])
    ],
    targets: [
        .target(name: "VaultLightCore"),
        .testTarget(name: "VaultLightCoreTests", dependencies: ["VaultLightCore"]),
    ]
)
