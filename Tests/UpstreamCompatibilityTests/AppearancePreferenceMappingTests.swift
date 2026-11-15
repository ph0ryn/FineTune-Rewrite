// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/AppearancePreferenceMappingTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Original imports and test bodies preserved; new production bridge lifecycle tests follow separately.

// FineTuneTests/AppearancePreferenceMappingTests.swift
// Tests that AppearancePreference maps to the correct SwiftUI ColorScheme
// and AppKit NSAppearance values. Pins the public contract used by the
// override mechanism.

import AppKit
import SwiftUI
import Testing

@testable import FineTune

@Suite("AppearancePreference — Resolution helpers")
@MainActor
struct AppearancePreferenceMappingTests {

  @Test("system resolves to a concrete ColorScheme matching live system appearance")
  func systemColorScheme() {
    let scheme = AppearancePreference.system.swiftUIColorScheme
    #expect(scheme != nil)
    let expected: ColorScheme =
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    #expect(scheme == expected)
  }

  @Test("light maps to ColorScheme.light")
  func lightColorScheme() {
    #expect(AppearancePreference.light.swiftUIColorScheme == .light)
  }

  @Test("dark maps to ColorScheme.dark")
  func darkColorScheme() {
    #expect(AppearancePreference.dark.swiftUIColorScheme == .dark)
  }

  @Test("system maps to nil NSAppearance (inherit from window/app)")
  func systemNSAppearance() {
    #expect(AppearancePreference.system.nsAppearance == nil)
  }

  @Test("light maps to NSAppearance(named: .aqua)")
  func lightNSAppearance() {
    let resolved = AppearancePreference.light.nsAppearance
    #expect(resolved?.name == .aqua)
  }

  @Test("dark maps to NSAppearance(named: .darkAqua)")
  func darkNSAppearance() {
    let resolved = AppearancePreference.dark.nsAppearance
    #expect(resolved?.name == .darkAqua)
  }
}
