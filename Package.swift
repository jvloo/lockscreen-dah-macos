// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LockscreenDah",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LockscreenDah",
            path: "Sources/LockscreenDah"
        )
    ]
)
