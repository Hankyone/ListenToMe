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
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
  ],
  targets: [
    .executableTarget(
      name: "ListenToMe",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
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
