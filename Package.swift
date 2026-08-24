// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SelectiveRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SelectiveRemote", targets: ["SelectiveRemote"]),
        .executable(
            name: "SelectiveRemoteTerminalBridge",
            targets: ["SelectiveRemoteTerminalBridge"]
        )
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
        .executableTarget(
            name: "SelectiveRemoteTerminalBridge",
            path: "Sources/SelectiveRemoteTerminalBridge"
        ),
        .testTarget(
            name: "SelectiveRemoteTests",
            dependencies: ["SelectiveRemote"],
            path: "Tests/SelectiveRemoteTests"
        )
    ]
)
