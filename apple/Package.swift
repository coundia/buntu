// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CndIptvNative",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .executable(
            name: "CndIptvApp",
            targets: ["CndIptvApp"]
        ),
    ],
    dependencies: [
        .package(path: "Packages/CndCoreBridge")
    ],
    targets: [
        .executableTarget(
            name: "CndIptvApp",
            dependencies: [
                .product(name: "CndCoreBridge", package: "CndCoreBridge")
            ],
            path: "Sources/CndIptvApp"
        ),
        .testTarget(
            name: "CndIptvAppTests",
            dependencies: ["CndIptvApp"],
            path: "Tests/CndIptvAppTests"
        ),
    ]
)
