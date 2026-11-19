// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoraApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CoraKit", targets: ["CoraKit"]),
        .executable(name: "Cora", targets: ["Cora"]),
    ],
    targets: [
        .target(name: "CoraKit"),
        .executableTarget(name: "Cora", dependencies: ["CoraKit"]),
        .testTarget(name: "CoraKitTests", dependencies: ["CoraKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
