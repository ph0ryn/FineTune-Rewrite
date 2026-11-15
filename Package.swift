// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The opt-in CLI has its own main-executable privacy metadata, never a library/test linker flag.
let probeInfo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Tools/AudioProbe/Info.plist").path

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
    .executable(name: "AudioProbe", targets: ["AudioProbe"]),
    .executable(name: "DSPTests", targets: ["DSPTests"]),
    .executable(name: "NativeStageTests", targets: ["NativeStageTests"]),
    .executable(name: "NativeSlotTests", targets: ["NativeSlotTests"]),
    .executable(name: "NativeLevelsTests", targets: ["NativeLevelsTests"]),
    .executable(name: "NativeRuntimeTests", targets: ["NativeRuntimeTests"]),
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
      ],
      linkerSettings: [.linkedFramework("IOBluetooth")]
    ),
    .target(
      name: "NativeAudio",
      dependencies: ["AudioDSP"],
      linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreAudio")]
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
      name: "AudioProbe",
      dependencies: ["FineTuneDomain", "FineTunePlatform", "FineTuneControl", "NativeAudio"],
      path: "Tools/AudioProbe", exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", probeInfo,
        ])
      ]
    ),
    .executableTarget(
      name: "DSPTests",
      dependencies: ["AudioDSP", "NativeAudio"],
      path: "Tools/DSPTests",
      sources: ["main.cpp", "LoudnessCompatibilityTests.cpp"]
    ),
    .executableTarget(
      name: "NativeStageTests", dependencies: ["NativeAudio"],
      path: "Tests/NativeStageTests", sources: ["main.cpp"]
    ),
    .executableTarget(
      name: "NativeSlotTests", dependencies: ["NativeAudio"],
      path: "Tests/NativeRuntimeTests", sources: ["CallbackSlotsTests.cpp"]
    ),
    .executableTarget(
      name: "NativeLevelsTests", dependencies: ["NativeAudio"],
      path: "Tests/NativeRuntimeTests", sources: ["CoherentLevelsTests.cpp"]
    ),
    .executableTarget(
      name: "NativeRuntimeTests", dependencies: ["NativeAudio"],
      path: "Tests/NativeRuntimeTests", sources: ["NativeRuntimeBoundaryTests.cpp"]
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
    // Independently authored MIT coverage split out of the mixed upstream suite.
    .testTarget(
      name: "IndependentCompatibilityTests",
      dependencies: ["FineTune", "FineTunePlatform"],
      swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]
    ),
    .testTarget(
      name: "NativeContractTests",
      dependencies: ["FineTunePlatform", "NativeAudio"]
    ),
    .testTarget(
      name: "AppCompositionTests",
      dependencies: [
        "FineTune", "FineTuneDomain", "FineTuneControl", "FineTunePlatform", "AppTestSupport",
      ]
    ),
    // Rendered UI/OCR/SCK suites moved out of AppCompositionTests; separate test bundle.
    .testTarget(
      name: "AppRenderedTests",
      dependencies: [
        "FineTune", "FineTuneControl", "FineTuneDomain", "FineTunePlatform",
        "AppTestSupport",
      ],
      path: "Tests/AppRenderedTests"
    ),
    // Shared test-only helpers; not a product and not importable by non-test code.
    .target(
      name: "AppTestSupport", dependencies: ["FineTuneControl", "FineTuneDomain"],
      path: "Tests/AppTestSupport"
    ),
    // Non-render policy contracts, isolated from the render/OCR suites' process.
    .testTarget(
      name: "AppPolicyContractTests",
      dependencies: ["FineTuneControl", "FineTuneDomain", "FineTunePlatform", "AppTestSupport"],
      path: "Tests/AppPolicyContractTests"
    ),
    // No-render copy/format/semantic contracts split out of the rendered UI suites.
    .testTarget(
      name: "AppPresentationContractTests",
      dependencies: ["FineTune", "FineTuneDomain"]
    ),
    .testTarget(
      name: "ControlTests",
      dependencies: ["FineTuneDomain", "FineTuneControl"]
    ),
    .testTarget(
      name: "DomainTests",
      dependencies: ["FineTuneDomain"]
    ),
    .testTarget(
      name: "PlatformTests",
      dependencies: ["FineTuneDomain", "FineTuneControl", "FineTunePlatform"]
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
