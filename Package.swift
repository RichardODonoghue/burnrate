// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BurnRate",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "BurnRate", targets: ["BurnRate"]),
        // Platform-independent core: no AppKit/SwiftUI/Combine/UserNotifications.
        .library(name: "BurnRateCore", targets: ["BurnRateCore"]),
    ],
    targets: [
        .target(
            name: "BurnRateCore",
            path: "Sources/BurnRateCore"
        ),
        .executableTarget(
            name: "BurnRate",
            dependencies: ["BurnRateCore"],
            path: "Sources/BurnRate"
        ),
        .testTarget(
            name: "BurnRateTests",
            dependencies: ["BurnRate", "BurnRateCore"],
            path: "Tests/BurnRateTests"
        ),
    ]
)
