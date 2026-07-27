// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "agent-notify",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "agent-notify",
            path: "Sources/AgentNotify",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
