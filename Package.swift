// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "redact-pdf",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "redact-pdf",
            path: "Sources/redact-pdf"
        )
    ]
)
