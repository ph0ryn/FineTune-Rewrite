// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/DeviceIconPickerTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Original test bodies preserved; AppKit/SwiftUI imports support the appended independent rendering test.

// FineTuneTests/DeviceIconPickerTests.swift

import AppKit
import SwiftUI
import Testing

@testable import FineTune

@Suite("DeviceIconPicker highlight rule")
struct DeviceIconPickerTests {

  @Test("Override symbol is highlighted when set")
  func overrideHighlighted() {
    let symbol = DeviceIconPicker.highlightSymbol(
      currentOverride: "gamecontroller.fill", automaticIsSymbol: true, automaticSymbol: "headphones"
    )
    #expect(symbol == "gamecontroller.fill")
  }

  @Test("Automatic suggested symbol is highlighted when no override")
  func automaticHighlighted() {
    let symbol = DeviceIconPicker.highlightSymbol(
      currentOverride: nil, automaticIsSymbol: true, automaticSymbol: "headphones")
    #expect(symbol == "headphones")
  }

  @Test("Nothing is highlighted when the automatic icon is a driver image")
  func driverImageHighlightsNothing() {
    let symbol = DeviceIconPicker.highlightSymbol(
      currentOverride: nil, automaticIsSymbol: false, automaticSymbol: "headphones")
    #expect(symbol == nil)
  }
}

@Suite("DeviceIconPicker suggested composition")
struct DeviceIconPickerSuggestedTests {

  @Test("Leading symbol comes first and is not duplicated from shared")
  func leadingFirstAndDeduped() {
    let symbols = DeviceIconPicker.composeSuggested(
      leading: "mic", shared: ["headphones", "mic", "headset"])
    #expect(symbols == ["mic", "headphones", "headset"])
  }

  @Test("Nil leading returns the shared suggestions unchanged")
  func nilLeadingPassesThrough() {
    let shared = ["headphones", "hifispeaker.fill", "headset"]
    #expect(DeviceIconPicker.composeSuggested(leading: nil, shared: shared) == shared)
  }
}
