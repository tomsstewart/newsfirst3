// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MisakiSwift",
  platforms: [
    .iOS(.v18), .macOS(.v15)
  ],
  products: [
    .library(
      name: "MisakiSwift",
      type: .dynamic,
      targets: ["MisakiSwift"]
    ),
  ],
  // MLX removed (vendored change): it cannot link against the iOS simulator SDK and
  // was only used by the BART OOV fallback, now replaced with letter-to-sound rules.
  dependencies: [],
  targets: [
    .target(
      name: "MisakiSwift",
      dependencies: [],
     resources: [
      .copy("G2PData")
     ]
    ),
    .testTarget(
      name: "MisakiSwiftTests",
      dependencies: ["MisakiSwift"]
    ),
  ]
)
