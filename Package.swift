// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "WattWhat",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "WattWhatCore", targets: ["WattWhatCore"])
  ],
  targets: [
    .target(
      name: "WattWhatCore",
      path: "Sources/WattWhatCore"
    ),
    .testTarget(
      name: "WattWhatCoreTests",
      dependencies: ["WattWhatCore"]
    ),
  ]
)
