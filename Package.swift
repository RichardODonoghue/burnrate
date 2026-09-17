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

#if os(Linux)
products.append(.executable(name: "BurnRate", targets: ["BurnRateLinux"]))
targets.append(.systemLibrary(
    name: "CGTK",
    path: "Sources/CGTK",
    pkgConfig: "gtk4",
    providers: [.apt(["libgtk-4-dev"])]
))
targets.append(.target(
    name: "CBurnRateGTK",
    dependencies: ["CGTK"],
    path: "Sources/CBurnRateGTK"
))
targets.append(.executableTarget(
    name: "BurnRateLinux",
    dependencies: ["BurnRateCore", "CBurnRateGTK"],
    path: "Sources/BurnRateLinux"
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
