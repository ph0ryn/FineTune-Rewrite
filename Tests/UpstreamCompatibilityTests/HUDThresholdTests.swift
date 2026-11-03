// SPDX-License-Identifier: GPL-3.0-only
// Derived from ronitsingh10/FineTune at 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Original test body follows unchanged.
// FineTuneTests/HUDThresholdTests.swift
// Verifies wave-icon glyph selection mirrors what the user sees on the bar/label
// (displayed integer percent), not internal float thresholds.

import SwiftUI
import Testing

@testable import FineTune

@Suite("HUD wave-icon thresholds use displayed-percent semantics")
struct HUDThresholdTests {
  @Test("Tahoe icon: 0% → speaker.fill (muted glyph)")
  func tahoeZeroPercent() {
    let hud = TahoeStyleHUD(sliderFraction: 0, mute: false, deviceName: "Test")
    #expect(hud.waveIconNameForTest == "speaker.fill")
  }

  @Test("Tahoe icon: 33% → wave.1")
  func tahoeLow() {
    let hud = TahoeStyleHUD(sliderFraction: 0.33, mute: false, deviceName: "Test")
    #expect(hud.waveIconNameForTest == "speaker.wave.1.fill")
  }

  @Test("Tahoe icon: 50% → wave.2")
  func tahoeMid() {
    let hud = TahoeStyleHUD(sliderFraction: 0.50, mute: false, deviceName: "Test")
    #expect(hud.waveIconNameForTest == "speaker.wave.2.fill")
  }

  @Test("Tahoe icon: 67% → wave.3")
  func tahoeHigh() {
    let hud = TahoeStyleHUD(sliderFraction: 0.67, mute: false, deviceName: "Test")
    #expect(hud.waveIconNameForTest == "speaker.wave.3.fill")
  }

  @Test("Tahoe icon: 100% → wave.3")
  func tahoeMax() {
    let hud = TahoeStyleHUD(sliderFraction: 1.0, mute: false, deviceName: "Test")
    #expect(hud.waveIconNameForTest == "speaker.wave.3.fill")
  }

  @Test("Classic icon: 0% → speaker.fill")
  func classicZeroPercent() {
    let hud = ClassicStyleHUD(sliderFraction: 0, mute: false)
    #expect(hud.waveIconNameForTest == "speaker.fill")
  }

  @Test("Classic icon: 33% → wave.1")
  func classicLow() {
    let hud = ClassicStyleHUD(sliderFraction: 0.33, mute: false)
    #expect(hud.waveIconNameForTest == "speaker.wave.1.fill")
  }
}
