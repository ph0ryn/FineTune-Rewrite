// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "FineTune",
  platforms: [.macOS("15.4")],
  products: [
    .library(name: "FineTuneDomain", targets: ["FineTuneDomain"]),
    .library(name: "FineTuneControl", targets: ["FineTuneControl"]),
    .library(name: "FineTunePlatform", targets: ["FineTunePlatform"]),
    .library(name: "NativeAudio", targets: ["NativeAudio"]),
    .library(name: "AudioDSP", targets: ["AudioDSP"]),
    .executable(name: "FineTune", targets: ["FineTune"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/sindresorhus/KeyboardShortcuts",
      revision: "1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27"
    )
  ],
  targets: [
    .target(name: "FineTuneDomain"),
    .target(name: "FineTuneControl", dependencies: ["FineTuneDomain"]),
    .target(
      name: "FineTunePlatform",
      dependencies: [
        "FineTuneDomain", "FineTuneControl", "NativeAudio",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ]
    ),
    .target(
      name: "NativeAudio",
      dependencies: ["AudioDSP"],
      linkerSettings: [.linkedFramework("Foundation")]
    ),
    .target(name: "AudioDSP"),
    .executableTarget(
      name: "FineTune",
      dependencies: [
        "FineTuneDomain", "FineTuneControl", "FineTunePlatform",
        .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      path: "App",
      resources: [.copy("Resources/ThirdPartyNotices.txt")]
    ),
    .executableTarget(
      name: "DSPTests",
      dependencies: ["AudioDSP", "NativeAudio"],
      path: "Tools/DSPTests",
      sources: ["main.cpp", "LoudnessCompatibilityTests.cpp"]
    ),
    .testTarget(
      name: "UpstreamCompatibilityTests",
      dependencies: [
        "FineTune", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
      ],
      exclude: ["COPYING", "README.md", "migrationManifest.json"],
      resources: [.copy("Fixtures")],
      // Match the fixed upstream Xcode test target without changing test bodies.
      swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]
    ),
    .target(
      name: "NativeBuildSupport",
      dependencies: ["NativeAudio", "AudioDSP"],
      path: "Tests/NativeBuildSupport",
      linkerSettings: [.linkedFramework("Foundation")]
    ),
    .testTarget(
      name: "BuildSmokeTests",
      dependencies: [
        "FineTuneDomain", "FineTuneControl", "FineTunePlatform", "NativeAudio",
        "NativeBuildSupport",
      ]
    ),
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx20
)
