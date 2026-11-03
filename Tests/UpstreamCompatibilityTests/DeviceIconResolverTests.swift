// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/DeviceIconResolverTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Imports and test body preserved.

// FineTuneTests/DeviceIconResolverTests.swift

import AppKit
import Testing

@testable import FineTune

@Suite("DeviceIconResolver")
struct DeviceIconResolverTests {
  private let automatic = NSImage(
    systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

  @Test("Valid override symbol wins over the automatic icon")
  func overrideWins() {
    let resolved = DeviceIconResolver.displayIcon(
      overrideSymbol: "gamecontroller.fill", automatic: automatic, deviceName: "Test"
    )
    #expect(resolved != nil)
    #expect(resolved !== automatic)
  }

  @Test("Nil override falls back to the automatic icon")
  func nilOverrideFallsBack() {
    let resolved = DeviceIconResolver.displayIcon(
      overrideSymbol: nil, automatic: automatic, deviceName: "Test"
    )
    #expect(resolved === automatic)
  }

  @Test("Unresolvable override falls back to the automatic icon")
  func invalidOverrideFallsBack() {
    let resolved = DeviceIconResolver.displayIcon(
      overrideSymbol: "not.a.real.symbol.zzz", automatic: automatic, deviceName: "Test"
    )
    #expect(resolved === automatic)
  }

  @Test("Unresolvable override with no automatic icon returns nil")
  func invalidOverrideNoAutomatic() {
    let resolved = DeviceIconResolver.displayIcon(
      overrideSymbol: "not.a.real.symbol.zzz", automatic: nil, deviceName: "Test"
    )
    #expect(resolved == nil)
  }
}
