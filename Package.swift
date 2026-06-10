// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ClaudeBarCore", targets: ["ClaudeBarCore"]),
        .executable(name: "ClaudeBar", targets: ["ClaudeBar"]),
        .executable(name: "ClaudeBarWatchdog", targets: ["ClaudeBarWatchdog"]),
    ],
    targets: [
        .target(
            name: "ClaudeBarCore",
            path: "Sources/ClaudeBarCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore"],
            path: "Sources/ClaudeBar",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/ProviderIcon-claude.svg"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ],
            linkerSettings: [
                // Embed Info.plist into the __TEXT,__info_plist section so the bare executable is
                // recognised as an LSUIElement agent (no Dock icon, no app menu).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ClaudeBar/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "ClaudeBarWatchdog",
            path: "Sources/ClaudeBarWatchdog",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"],
            path: "Tests/ClaudeBarCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
        .testTarget(
            name: "ClaudeBarTests",
            dependencies: ["ClaudeBar"],
            path: "Tests/ClaudeBarTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
