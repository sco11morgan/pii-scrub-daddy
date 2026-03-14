// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pii-scrub-daddy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PIIScrubCore",
            path: "Sources/PIIScrubCore"
        ),
        .executableTarget(
            name: "piiscrub",
            dependencies: ["PIIScrubCore"],
            path: "Sources/piiscrub"
        ),
        .testTarget(
            name: "PIIScrubDaddyTests",
            dependencies: ["PIIScrubCore"],
            path: "Tests/PIIScrubDaddyTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
