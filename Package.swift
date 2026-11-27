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
      exclude: ["Resources/AppIcon.icon"],
      resources: [
        .copy("Resources/THIRD_PARTY_NOTICES.txt"),
        .process("Resources/MenuBarIcon.png"),
        .process("Resources/MenuBarIcon@2x.png"),
      ]
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
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx20
)
