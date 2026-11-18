// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune (FineTuneTests/{AppearancePreferenceMappingTests,
// DesignTokensTests,DesignTokensDynamicResolutionTests,MuteButtonColorInvariantTests,
// DeviceIconCatalogTests,DeviceIconPickerTests,DeviceIconResolverTests,
// AudioDeviceIconSymbolTests,DeviceInspectorInfoGridTests}.swift)
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51

import AppKit
import AudioToolbox
import CoreAudio
import FineTuneDomain
import Foundation
import SwiftUI
import Testing

@testable import FineTune

@MainActor
private func compatResolveColor(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
  var resolved = color
  appearance.performAsCurrentDrawingAppearance {
    resolved = color.usingColorSpace(.sRGB) ?? color
  }
  return resolved
}

@MainActor
private func compatExpectColor(
  _ dynamic: Color,
  equals expected: NSColor,
  in appearance: NSAppearance,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let actual = compatResolveColor(NSColor(dynamic), in: appearance)
  let target = compatResolveColor(expected, in: appearance)
  #expect(abs(actual.redComponent - target.redComponent) < 0.01, sourceLocation: sourceLocation)
  #expect(abs(actual.greenComponent - target.greenComponent) < 0.01, sourceLocation: sourceLocation)
  #expect(abs(actual.blueComponent - target.blueComponent) < 0.01, sourceLocation: sourceLocation)
  #expect(abs(actual.alphaComponent - target.alphaComponent) < 0.01, sourceLocation: sourceLocation)
}

// MARK: - AppearancePreference Mapping

@Suite("Upstream AppearancePreference Mapping Compatibility")
@MainActor
struct UpstreamAppearancePreferenceMappingTests {

  @Test("nsAppearance matches all cases")
  func appKitMapping() {
    #expect(AppearancePreference.system.nsAppearance == nil)
    #expect(AppearancePreference.light.nsAppearance?.name == .aqua)
    #expect(AppearancePreference.dark.nsAppearance?.name == .darkAqua)
  }

  @Test("swiftUIColorScheme matches all cases")
  func swiftUIMapping() {
    let expectedSystem: ColorScheme =
      NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? .dark : .light
    #expect(AppearancePreference.system.swiftUIColorScheme == expectedSystem)
    #expect(AppearancePreference.light.swiftUIColorScheme == .light)
    #expect(AppearancePreference.dark.swiftUIColorScheme == .dark)
  }
}

// MARK: - DesignTokens & MuteButton Invariants

@Suite("Upstream DesignTokens Compatibility")
@MainActor
struct UpstreamDesignTokensCompatibilityTests {

  private static let aqua = NSAppearance(named: .aqua)!
  private static let darkAqua = NSAppearance(named: .darkAqua)!

  @Test("Interactive tint and layout dimensions remain positive")
  func staticAccentTokens() {
    let interactive = compatResolveColor(
      NSColor(DesignTokens.Colors.interactiveHover), in: Self.darkAqua)
    #expect(interactive.alphaComponent > 0)
    let active = compatResolveColor(
      NSColor(DesignTokens.Colors.interactiveActive), in: Self.darkAqua)
    #expect(active.alphaComponent > 0)
    #expect(DesignTokens.Dimensions.cornerRadius > 0)
    #expect(DesignTokens.Dimensions.iconSize > 0)
    #expect(DesignTokens.Dimensions.popupWidth > 0)
  }

  @Test("Dynamic light/dark colors resolve to exact sRGB outputs")
  func dynamicTokenPairs() {
    compatExpectColor(DesignTokens.Colors.menuBackground, equals: NSColor.clear, in: Self.aqua)
    compatExpectColor(DesignTokens.Colors.menuBackground, equals: NSColor.clear, in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.popupOverlay,
      equals: NSColor.white.withAlphaComponent(0.50),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.popupOverlay,
      equals: NSColor.black.withAlphaComponent(0.40),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.recessedBackground,
      equals: NSColor.black.withAlphaComponent(0.04),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.recessedBackground,
      equals: NSColor.black.withAlphaComponent(0.30),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.menuBorder,
      equals: NSColor.black.withAlphaComponent(0.18),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.menuBorder,
      equals: NSColor.white.withAlphaComponent(0.12),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.menuBorderHover,
      equals: NSColor.black.withAlphaComponent(0.32),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.menuBorderHover,
      equals: NSColor.white.withAlphaComponent(0.25),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.autoEQEmptyBorder,
      equals: NSColor.black.withAlphaComponent(0.22),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.autoEQEmptyBorder,
      equals: NSColor.white.withAlphaComponent(0.1),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.autoEQEmptyIcon,
      equals: NSColor(white: 0.45, alpha: 1.0),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.autoEQEmptyIcon,
      equals: NSColor(white: 0.267, alpha: 1.0),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.autoEQToggleLabel,
      equals: NSColor.black.withAlphaComponent(0.65),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.autoEQToggleLabel,
      equals: NSColor.white.withAlphaComponent(0.5),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.hoverSurface,
      equals: NSColor.black.withAlphaComponent(0.115),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.hoverSurface,
      equals: NSColor.white.withAlphaComponent(0.07),
      in: Self.darkAqua)

    compatExpectColor(DesignTokens.Colors.glassFill, equals: NSColor.clear, in: Self.aqua)
    compatExpectColor(DesignTokens.Colors.glassFill, equals: NSColor.clear, in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.glassFillStrong,
      equals: NSColor.white.withAlphaComponent(0.85),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.glassFillStrong,
      equals: NSColor.white.withAlphaComponent(0.1),
      in: Self.darkAqua)

    compatExpectColor(DesignTokens.Colors.glassRowBorder, equals: NSColor.clear, in: Self.aqua)
    compatExpectColor(DesignTokens.Colors.glassRowBorder, equals: NSColor.clear, in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.glassRowBorderHover,
      equals: NSColor.black.withAlphaComponent(0.10),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.glassRowBorderHover,
      equals: NSColor.white.withAlphaComponent(0.15),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.hudBorder,
      equals: NSColor.black.withAlphaComponent(0.15),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.hudBorder,
      equals: NSColor.white.withAlphaComponent(0.08),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.sectionHeaderText,
      equals: NSColor.black.withAlphaComponent(0.65),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.sectionHeaderText,
      equals: NSColor.white.withAlphaComponent(0.40),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.eqCardBackground,
      equals: NSColor.white.withAlphaComponent(0.78),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.eqCardBackground,
      equals: NSColor.white.withAlphaComponent(0.07),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.eqCardBorder,
      equals: NSColor.black.withAlphaComponent(0.06),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.eqCardBorder,
      equals: NSColor.white.withAlphaComponent(0.10),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.deviceBadgeMonoFill,
      equals: NSColor.black.withAlphaComponent(0.10),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.deviceBadgeMonoFill,
      equals: NSColor.white.withAlphaComponent(0.10),
      in: Self.darkAqua)

    compatExpectColor(
      DesignTokens.Colors.deviceBadgeMonoForeground,
      equals: NSColor.black.withAlphaComponent(0.65),
      in: Self.aqua)
    compatExpectColor(
      DesignTokens.Colors.deviceBadgeMonoForeground,
      equals: NSColor.white.withAlphaComponent(0.70),
      in: Self.darkAqua)
  }

  @Test("Mute indicator color has clear red chroma and alpha across light and dark appearances")
  func muteIndicatorColorInvariant() {
    for appearance in [Self.aqua, Self.darkAqua] {
      let mutedRed = compatResolveColor(
        NSColor(DesignTokens.Colors.mutedIndicator), in: appearance)
      #expect(mutedRed.alphaComponent > 0.7)
      #expect(mutedRed.redComponent > mutedRed.greenComponent + 0.2)
      #expect(mutedRed.redComponent > mutedRed.blueComponent + 0.2)
    }
  }
}

// MARK: - Device Icons & Inspector Compatibility

@Suite("Upstream DeviceIcon & Inspector Compatibility")
@MainActor
struct UpstreamDeviceIconCompatibilityTests {

  @Test("DeviceIconCatalog entries have valid SF symbols, unique symbols, and non-empty keywords")
  func catalogValidation() {
    let entries = DeviceIconCatalog.allEntries
    #expect(!entries.isEmpty)
    let symbols = entries.map(\.symbol)
    #expect(Set(symbols).count == symbols.count)
    for entry in entries {
      #expect(!entry.keywords.isEmpty)
      #expect(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil)
    }
    #expect(DeviceIconCatalog.matching("").map(\.symbol) == symbols)
  }

  @Test("DeviceIconResolver prefers valid override symbol and falls back to automatic NSImage")
  func iconResolverPrecedence() {
    let automatic = NSImage(size: NSSize(width: 16, height: 16))
    let resolvedOverride = DeviceIconResolver.displayIcon(
      overrideSymbol: "headphones", automatic: automatic, deviceName: "Test")
    #expect(resolvedOverride != nil)
    #expect(resolvedOverride !== automatic)

    let resolvedFallback = DeviceIconResolver.displayIcon(
      overrideSymbol: nil, automatic: automatic, deviceName: "Test")
    #expect(resolvedFallback === automatic)

    let invalidOverride = DeviceIconResolver.displayIcon(
      overrideSymbol: "not-a-real-sf-symbol-name-xyz",
      automatic: automatic,
      deviceName: "Test"
    )
    #expect(invalidOverride === automatic)
  }

  @Test("DeviceIconSymbol maps AirPods, headphones, displays, and transport defaults cleanly")
  func audioDeviceIconSymbol() {
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "AirPods Pro", transport: .bluetooth) == "airpodspro")
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "AirPods Max", transport: .bluetooth) == "airpodsmax")
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "MacBook Pro Speakers", transport: .builtIn) == "macbook"
    )
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "Studio Display", transport: .displayPort) == "display")
    #expect(!DeviceIconSymbol.iconSymbol(forName: "Generic Device", transport: .usb).isEmpty)
  }

  @Test("DeviceIconPicker highlightSymbol and composeSuggested obey selection rules")
  func iconPickerHelpers() {
    #expect(
      DeviceIconPicker.highlightSymbol(
        currentOverride: "airpodspro", automaticIsSymbol: true, automaticSymbol: "headphones")
        == "airpodspro")
    #expect(
      DeviceIconPicker.highlightSymbol(
        currentOverride: nil, automaticIsSymbol: true, automaticSymbol: "headphones")
        == "headphones")
    #expect(
      DeviceIconPicker.highlightSymbol(
        currentOverride: nil, automaticIsSymbol: false, automaticSymbol: "headphones")
        == nil)
    let suggested = DeviceIconPicker.composeSuggested(
      leading: "hifispeaker", shared: ["headphones", "hifispeaker", "airpodspro"])
    #expect(suggested == ["hifispeaker", "headphones", "airpodspro"])
  }

  @Test("InfoGridLayout and DeviceInspectorInfo format sample rate, format, and device ID cleanly")
  func inspectorInfoGridFormatting() {
    #expect(DeviceInspectorInfo.formatSampleRate(48000) == "48 kHz")
    #expect(DeviceInspectorInfo.formatSampleRate(44100) == "44.1 kHz")
    #expect(DeviceInspectorInfo.formatSampleRate(0) == "—")

    let info = DeviceInspectorInfo(
      transportLabel: "USB",
      sampleRate: 48000,
      availableSampleRates: [44100, 48000],
      sampleRateSettable: true,
      formatLabel: "2ch / 24-bit",
      hogModeOwner: -1,
      uid: "usb-dev-1"
    )
    let layout = InfoGridLayout(info: info)
    #expect(layout.rows.count == 4)
    #expect(layout.rows[0] == .transport("USB"))
    #expect(
      layout.rows[1] == .sampleRate(display: "48 kHz", isPicker: true, options: [44100, 48000]))
    #expect(layout.rows[2] == .format("2ch / 24-bit"))
    #expect(layout.rows[3] == .deviceID("usb-dev-1"))
  }
}
