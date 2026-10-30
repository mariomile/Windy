// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Windy",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "WindyCore"),
        .executableTarget(name: "Windy", dependencies: ["WindyCore"]),
        .testTarget(name: "WindyCoreTests", dependencies: ["WindyCore"]),
    ],
    swiftLanguageModes: [.v5]
)
