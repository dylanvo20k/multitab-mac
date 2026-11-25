// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Multitab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Multitab", path: "Sources/Multitab")
    ]
)
