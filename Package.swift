// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "kagete",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "kagete",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "kageteTests",
            dependencies: ["kagete"]
        ),
    ]
)
