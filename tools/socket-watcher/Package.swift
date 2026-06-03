// swift-tools-version:5.9
// Standalone SwiftPM package for the C11-105 socket-unlink diagnostic watcher.
// See ../../docs/c11-socket-unlink-diagnostic.md for the runbook.
//
// Build: swift build -c release
// Run:   swift run c11-socket-watcher watch <path>
// Test:  swift test

import PackageDescription

let package = Package(
    name: "socket-watcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "c11-socket-watcher", targets: ["c11-socket-watcher"]),
        .library(name: "SocketWatcherKit", targets: ["SocketWatcherKit"])
    ],
    targets: [
        .executableTarget(
            name: "c11-socket-watcher",
            dependencies: ["SocketWatcherKit"],
            path: "Sources/c11-socket-watcher"
        ),
        .target(
            name: "SocketWatcherKit",
            path: "Sources/SocketWatcherKit"
        ),
        .testTarget(
            name: "SocketWatcherKitTests",
            dependencies: ["SocketWatcherKit"],
            path: "Tests/SocketWatcherKitTests"
        )
    ]
)
