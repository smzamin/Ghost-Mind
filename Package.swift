// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GhostMind",
    platforms: [
        .macOS(.v13)  // macOS Ventura minimum (NSWindow.SharingType.none requires 12+, SCKit requires 12.3+)
    ],
    products: [
        .executable(name: "GhostMind", targets: ["GhostMind"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GhostMind",
            path: "GhostMind/Sources",
            resources: [
                .process("../Resources/Info.plist"),
                .process("../Resources/GhostMind.entitlements"),
            ],
            swiftSettings: [
                // Native ARM build only
                .unsafeFlags(["-target", "arm64-apple-macosx13.0"]),
                // Enable strict concurrency for Swift 6
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "GhostMindTests",
            dependencies: ["GhostMind"],
            path: "GhostMind/Tests"
        )
    ]
)
