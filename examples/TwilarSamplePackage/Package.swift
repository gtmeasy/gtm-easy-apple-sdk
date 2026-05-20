// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TwilarSampleFeature",
    // iOS-only: the feature module uses NavigationStack + iOS-only modifiers
    // (textInputAutocapitalization, .topBarTrailing, etc.) so we drop macOS
    // support rather than littering #if os(iOS) across every view.
    platforms: [.iOS(.v16)],
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
