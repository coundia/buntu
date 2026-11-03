// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CndIptvNative",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .executable(
            name: "CndIptvApp",
            targets: ["CndIptvApp"]
        ),
        // Everything but the entry point: the interface, the player, the models. The tests target it.
        .library(
            name: "CndIptvKit",
            targets: ["CndIptvKit"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/CndCoreBridge")
    ],
    targets: [
        .target(
            name: "CndIptvKit",
            dependencies: [
                .product(name: "CndCoreBridge", package: "CndCoreBridge")
            ],
            path: "Sources/CndIptvKit"
        ),
        .executableTarget(
            name: "CndIptvApp",
            dependencies: ["CndIptvKit"],
            path: "Sources/CndIptvApp"
        ),
        .testTarget(
            name: "CndIptvAppTests",
            dependencies: ["CndIptvKit"],
            path: "Tests/CndIptvAppTests"
        ),
    ]
)
