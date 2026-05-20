// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TwilarSampleFeature",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [
        .library(
            name: "TwilarSampleFeature",
            targets: ["TwilarSampleFeature"]
        ),
    ],
    dependencies: [
        // Local checkout of the GTM Easy Growth Apple SDK — relative path
        // walks out of the example back to the package root.
        .package(name: "GTMEasyGrowth", path: "../../"),
    ],
    targets: [
        .target(
            name: "TwilarSampleFeature",
            dependencies: [
                .product(name: "GTMEasyGrowth", package: "GTMEasyGrowth"),
            ]
        ),
        .testTarget(
            name: "TwilarSampleFeatureTests",
            dependencies: [
                "TwilarSampleFeature"
            ]
        ),
    ]
)
