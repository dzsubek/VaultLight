// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaultLightCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaultLightCore", targets: ["VaultLightCore"])
    ],
    targets: [
        .target(name: "VaultLightCore", resources: [.process("Resources/Localizable.xcstrings")]),
        .testTarget(name: "VaultLightCoreTests", dependencies: ["VaultLightCore"]),
    ]
)
