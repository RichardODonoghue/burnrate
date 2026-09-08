// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BurnRate",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "BurnRate",
            path: "Sources/BurnRate"
        ),
        .testTarget(
            name: "BurnRateTests",
            dependencies: ["BurnRate"],
            path: "Tests/BurnRateTests"
        ),
    ]
)
