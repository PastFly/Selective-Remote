// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SelectiveRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SelectiveRemote", targets: ["SelectiveRemote"])
    ],
    targets: [
        .target(
            name: "PTYBridge",
            path: "Sources/PTYBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SelectiveRemote",
            dependencies: ["PTYBridge"],
            path: "Sources/SelectiveRemote",
            exclude: ["TerminalResources"]
        ),
        .testTarget(
            name: "SelectiveRemoteTests",
            dependencies: ["SelectiveRemote"],
            path: "Tests/SelectiveRemoteTests"
        )
    ]
)
