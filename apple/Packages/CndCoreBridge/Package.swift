// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CndCoreBridge",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "CndCoreBridge",
            targets: ["CndCoreBridge"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "cnd_coreFFI",
            path: "cnd_coreFFI.xcframework"
        ),
        .target(
            name: "CndCoreBridge",
            dependencies: [
                .target(name: "cnd_coreFFI")
            ],
            path: "Sources/CndCoreBridge"
        ),
        .testTarget(
            name: "CndCoreBridgeTests",
            dependencies: ["CndCoreBridge"],
            path: "Tests/CndCoreBridgeTests"
        ),
    ]
)

