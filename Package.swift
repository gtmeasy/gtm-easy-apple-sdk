// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "GTMEasyGrowth",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "GTMEasyGrowth", targets: ["GTMEasyGrowth"]),
  ],
  targets: [
    .target(name: "GTMEasyGrowth"),
    .testTarget(name: "GTMEasyGrowthTests", dependencies: ["GTMEasyGrowth"]),
  ]
)
