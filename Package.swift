// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pii-scrub-daddy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "piiscrub",
            path: "Sources/piiscrub"
        )
    ]
)
