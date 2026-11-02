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
  ],
  targets: [
    .target(name: "FineTuneDomain"),
    .target(name: "FineTuneControl", dependencies: ["FineTuneDomain"]),
    .target(
      name: "FineTunePlatform",
      dependencies: ["FineTuneDomain", "FineTuneControl", "NativeAudio"]
    ),
    .target(
      name: "NativeAudio",
      dependencies: ["AudioDSP"],
      linkerSettings: [.linkedFramework("Foundation")]
    ),
    .target(name: "AudioDSP"),
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
