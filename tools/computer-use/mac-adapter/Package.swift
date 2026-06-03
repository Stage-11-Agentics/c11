// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CUAMacAdapter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "cua-mac-adapter", targets: ["CUAMacAdapter"]),
    ],
    targets: [
        .executableTarget(
            name: "CUAMacAdapter"
        ),
    ]
)
