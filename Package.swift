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
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .unsafeFlags(["-strict-concurrency=complete"]),
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
    ],
    swiftLanguageModes: [.v6]
)
