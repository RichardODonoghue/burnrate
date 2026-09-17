// swift-tools-version:6.0
import PackageDescription

// Platform-independent core (plus its tests) is always built. The macOS app
// and the Linux front-end are only declared on their own OS so a `swift build`
// on either platform never tries to compile the other's UI frameworks.

var products: [Product] = [
    .library(name: "BurnRateCore", targets: ["BurnRateCore"]),
]

var targets: [Target] = [
    .target(
        name: "BurnRateCore",
        path: "Sources/BurnRateCore"
    ),
    .testTarget(
        name: "BurnRateCoreTests",
        dependencies: ["BurnRateCore"],
        path: "Tests/BurnRateCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "BurnRate", targets: ["BurnRate"]))
targets.append(.executableTarget(
    name: "BurnRate",
    dependencies: ["BurnRateCore"],
    path: "Sources/BurnRate"
))
targets.append(.testTarget(
    name: "BurnRateTests",
    dependencies: ["BurnRate", "BurnRateCore"],
    path: "Tests/BurnRateTests"
))
#endif

let package = Package(
    name: "BurnRate",
    platforms: [
        .macOS(.v15)
    ],
    products: products,
    targets: targets
)
