// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "c11",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "c11", targets: ["c11"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "c11",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
