// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoraApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CoraKit"),
        .executableTarget(name: "Cora", dependencies: ["CoraKit"]),
        .testTarget(name: "CoraKitTests", dependencies: ["CoraKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
