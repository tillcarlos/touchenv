// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "touchenv",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "TouchEnvLib",
            path: "Sources/TouchEnvLib"
        ),
        .executableTarget(
            name: "touchenv",
            dependencies: ["TouchEnvLib"],
            path: "Sources/touchenv"
        ),
        .testTarget(
            name: "TouchEnvLibTests",
            dependencies: ["TouchEnvLib"]
        ),
    ]
)
