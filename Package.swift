// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "saveclip",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-testing", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "SaveClipLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/saveclip",
            exclude: ["EntryPoint.swift"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "saveclip",
            dependencies: ["SaveClipLib"],
            path: "Sources/saveclip-exe"
        ),
        .testTarget(
            name: "saveclipTests",
            dependencies: [
                "SaveClipLib",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
    ]
)
