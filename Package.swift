// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "touchenv",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "touchenv",
            path: "Sources"
        )
    ]
)
