// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "WattWhat",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "WattWhatCore", targets: ["WattWhatCore"]),
    .executable(name: "wattwhat-helper", targets: ["WattWhatHelper"]),
    .executable(name: "wattctl", targets: ["WattWhatCLI"]),
  ],
  targets: [
    .target(
      name: "WattWhatCore",
      path: "Sources/WattWhatCore"
    ),
    .executableTarget(
      name: "WattWhatHelper",
      dependencies: ["WattWhatCore"],
      path: "Sources/WattWhatHelper"
    ),
    .executableTarget(
      name: "WattWhatCLI",
      dependencies: ["WattWhatCore"],
      path: "Sources/WattWhatCLI"
    ),
    .testTarget(
      name: "WattWhatCoreTests",
      dependencies: ["WattWhatCore"]
    ),
  ]
)
