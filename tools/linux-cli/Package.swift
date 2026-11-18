// swift-tools-version:6.0
// The c11 CLI (`c11`) for Linux: the same Swift files the Xcode `c11-cli` target compiles (sources.txt), staged by
// build.sh into .stage/Sources/c11. The files import three Apple modules unconditionally; in the staged copy build.sh
// rewrites `import Darwin` to the C library (Glibc or Musl) and `import CryptoKit` to swift-crypto's `Crypto` (CryptoKit's
// API), and `import SQLite3` resolves to the system module below. (A module named Darwin would leak into dependencies:
// swift-crypto's canImport(Darwin) would turn true.) Security, Sentry and LocalAuthentication are imported under
// #if canImport, so on Linux they are absent. macOS builds never read this file; they use GhosttyTabs.xcodeproj.
import Foundation
import PackageDescription

// build.sh --static sets this: musl has no libsqlite3, so the SQLite amalgamation is compiled in as the SQLite3 module.
let sqliteAmalgamation = ProcessInfo.processInfo.environment["C11_LINUX_SQLITE"] == "amalgamation"

let package = Package(
    name: "c11-linux",
    products: [.executable(name: "c11", targets: ["c11"])],
    dependencies: [
        // Exact, with Package.resolved committed beside this file: the relay's HMACs are computed by this library.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .executableTarget(
            name: "c11",
            dependencies: [.product(name: "Crypto", package: "swift-crypto"), "SQLite3", "OSLog", "os"],
            path: "Sources/c11"
        ),
        // `import SQLite3`: the system's libsqlite3 (glibc builds) or the amalgamation build.sh fetches (static musl builds).
        sqliteAmalgamation
            ? .target(name: "SQLite3", path: "Shims/SQLite3Amalgamation",
                      cSettings: [.define("SQLITE_THREADSAFE", to: "1"), .define("SQLITE_OMIT_LOAD_EXTENSION"),
                                  .define("SQLITE_DQS", to: "0")])
            : .systemLibrary(name: "SQLite3", path: "Shims/SQLite3"),
        // `import OSLog` / `import os`: the Logger calls two HC files make; nothing is written on Linux.
        .target(name: "OSLog", path: "Shims/OSLog"),
        .target(name: "os", dependencies: ["OSLog"], path: "Shims/os"),
    ],
    swiftLanguageModes: [.v5]
)
