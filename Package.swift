// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ReelForge",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReelForge", targets: ["ReelForgeMac"]),
    ],
    targets: [
        .executableTarget(
            name: "ReelForgeMac",
            path: "Sources/ReelForgeMac"
        ),
        .testTarget(
            name: "ReelForgeTests",
            dependencies: ["ReelForgeMac"],
            path: "Tests/ReelForgeTests"
        ),
    ]
)
