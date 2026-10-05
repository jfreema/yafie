// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Yafie",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Yafie", path: "Sources/Yafie"),
        .testTarget(name: "YafieTests", dependencies: ["Yafie"], path: "Tests/YafieTests"),
    ]
)
