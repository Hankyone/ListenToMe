// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ListenToMe",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "ListenToMe", targets: ["ListenToMe"])
  ],
  targets: [
    .executableTarget(
      name: "ListenToMe",
      path: "Sources/ListenToMe",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "ListenToMeTests",
      dependencies: ["ListenToMe"],
      path: "Tests/ListenToMeTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
