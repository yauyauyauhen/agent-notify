// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "agent-notify",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "BundleHook",
            path: "Sources/BundleHook",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "agent-notify",
            dependencies: ["BundleHook"],
            path: "Sources/AgentNotify",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AgentNotify/Info.plist",
                ]),
            ]
        ),
    ]
)
