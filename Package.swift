// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IzMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "IzMac"),
        .testTarget(name: "IzMacTests", dependencies: ["IzMac"]),
    ]
)
