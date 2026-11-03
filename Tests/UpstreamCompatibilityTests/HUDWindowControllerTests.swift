// SPDX-License-Identifier: GPL-3.0-only
// Derived from ronitsingh10/FineTune at 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Original assertions/inputs retained. Environment adaptations: AppKit bootstrap and isolated launch-at-login service.
// FineTuneTests/HUDWindowControllerTests.swift
// Tests for HUDWindowController: position math, hide-timer reset semantics,
// style-specific hide delay, and popup-guard behavior.
//
// NSPanel/NSScreen creation is avoided — position math is tested via the pure
// static method, and timer behavior is tested via the hideDelayOverride hook.

import AppKit
import Foundation
import Testing

@testable import FineTune

@Suite("HUDWindowController — computePosition()")
@MainActor
struct HUDWindowControllerPositionTests {

  private let screen = NSRect(x: 0, y: 23, width: 1440, height: 877)  // typical macOS visible frame

  // MARK: - Tahoe style

  @Test("Tahoe style places HUD at top-right, inset 8pt from edges (AC #16)")
  func tahoeTopRight() {
    let size = NSSize(width: 300, height: 72)
    let pt = HUDWindowController.computePosition(
      style: .tahoe,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: false
    )
    let expectedX = screen.maxX - size.width - 8
    let expectedY = screen.maxY - size.height - 8
    #expect(pt.x == expectedX)
    #expect(pt.y == expectedY)
  }

  @Test("Tahoe style shifts to upper-left quarter when suppressionDegraded (AC #15 formula)")
  func tahoeSuppressionDegraded() {
    let size = NSSize(width: 300, height: 72)
    let pt = HUDWindowController.computePosition(
      style: .tahoe,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: true
    )
    let expectedX = screen.minX + screen.width * 0.25 - size.width / 2
    let expectedY = screen.maxY - size.height - 8
    #expect(pt.x == expectedX)
    #expect(pt.y == expectedY)
  }

  @Test("B12 position formula holds across varying visibleFrame widths")
  func tahoeSuppressionDegradedFormulaHolds() {
    // AC #15 worked example: vf.width = 1440 → x = 360 − 150 = 210.
    let size = NSSize(width: 300, height: 72)
    let frames: [NSRect] = [
      NSRect(x: 0, y: 23, width: 1440, height: 877),
      NSRect(x: 0, y: 23, width: 1920, height: 1057),
      NSRect(x: 0, y: 23, width: 2560, height: 1417),
    ]
    for vf in frames {
      let pt = HUDWindowController.computePosition(
        style: .tahoe,
        size: size,
        visibleFrame: vf,
        suppressionDegraded: true
      )
      #expect(pt.x == vf.minX + vf.width * 0.25 - size.width / 2)
      #expect(pt.y == vf.maxY - size.height - 8)
    }
  }

  // MARK: - Classic style

  @Test("Classic style centers horizontally, 140pt above screen bottom")
  func classicCenterBottom() {
    let size = NSSize(width: 200, height: 200)
    let pt = HUDWindowController.computePosition(
      style: .classic,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: false
    )
    let expectedX = screen.midX - size.width / 2
    let expectedY = screen.minY + 140
    #expect(pt.x == expectedX)
    #expect(pt.y == expectedY)
  }

  @Test("Classic style position is unchanged when suppressionDegraded")
  func classicSuppressionDegradedUnchanged() {
    let size = NSSize(width: 200, height: 200)
    let normal = HUDWindowController.computePosition(
      style: .classic,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: false
    )
    let degraded = HUDWindowController.computePosition(
      style: .classic,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: true
    )
    #expect(normal == degraded)
  }

  // MARK: - Edge cases

  @Test("Tahoe with zero-size HUD lands at top-right corner minus 8pt")
  func tahoeZeroSize() {
    let size = NSSize.zero
    let pt = HUDWindowController.computePosition(
      style: .tahoe,
      size: size,
      visibleFrame: screen,
      suppressionDegraded: false
    )
    #expect(pt.x == screen.maxX - 8)
    #expect(pt.y == screen.maxY - 8)
  }
}

// MARK: - Hide timer + style-specific delay

@Suite("HUDWindowController — hide timer + per-style delay")
@MainActor
struct HUDWindowControllerTimerTests {
  // Environment adaptation: XCTest/Swift Testing does not run the app's main entry point.
  init() { _ = NSApplication.shared }

  private func makeController(popupVisible: Bool = false) -> HUDWindowController {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(
      directory: tempDir, launchAtLoginService: TestLaunchAtLoginService())
    let status = MediaKeyStatus()
    let popup = PopupVisibilityService()
    popup.isVisible = popupVisible
    let hud = HUDWindowController(
      settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
    // Stub out frame to avoid real NSScreen in tests.
    hud.frameProvider = { NSRect(x: 0, y: 23, width: 1440, height: 877) }
    // These tests isolate popup/timer behavior from the user's current foreground window.
    hud.fullscreenProvider = { false }
    return hud
  }

  @Test("showCallCount increments on each show()")
  func showCallCountIncrements() {
    let hud = makeController()
    #expect(hud.showCallCount == 0)
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
    #expect(hud.showCallCount == 1)
    hud.show(sliderFraction: 0.6, mute: false, deviceName: "")
    #expect(hud.showCallCount == 2)
  }

  @Test("showCallCount increments even when the show is guard-skipped (counter tracks attempts)")
  func showCallCountTracksAttempts() {
    // showCallCount is incremented before the fullscreen + popup guards, so
    // it records every attempt regardless of whether the panel is actually shown.
    let hud = makeController()
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "")
    #expect(hud.showCallCount == 2)
  }

  @Test("Two rapid show() calls result in exactly two increments")
  func twoRapidShowsIncrementTwice() {
    let hud = makeController()
    hud.show(sliderFraction: 0.3, mute: false, deviceName: "")
    hud.show(sliderFraction: 0.4, mute: true, deviceName: "")
    #expect(hud.showCallCount == 2)
  }

  // MARK: - Per-style hide delay (AC #17)

  @Test("hideDelay is 1100 ms for both styles")
  func hideDelayIs1100msForBothStyles() {
    let hud = makeController()
    #expect(hud.hideDelay(for: .tahoe) == .milliseconds(1100))
    #expect(hud.hideDelay(for: .classic) == .milliseconds(1100))
  }

  @Test("hideDelayOverride applies uniformly to both styles")
  func hideDelayOverrideApplies() {
    let hud = makeController()
    hud.hideDelayOverride = .milliseconds(250)
    #expect(hud.hideDelay(for: .tahoe) == .milliseconds(250))
    #expect(hud.hideDelay(for: .classic) == .milliseconds(250))
  }

  // MARK: - Popup-visibility guard (AC #23)

  @Test("popupGuardSuppressesShow: popup visible ⇒ show() does not update panel")
  func popupGuardSuppressesShow() {
    let hud = makeController(popupVisible: true)
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Test Device")
    // Attempt is counted, but panel was not updated.
    #expect(hud.showCallCount == 1)
    #expect(hud.showDidUpdatePanel == false)
  }

  @Test("Popup hidden ⇒ show() updates panel")
  func popupHiddenShowUpdatesPanel() {
    let hud = makeController(popupVisible: false)
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Test Device")
    #expect(hud.showCallCount == 1)
    #expect(hud.showDidUpdatePanel == true)
  }
}

// Independent rewrite coverage: verify real presentation and timer/resource behavior,
// rather than satisfying the upstream diagnostic counters with a no-op presenter.
@Suite("Rewrite HUD presentation lifecycle", .serialized)
@MainActor
struct RewriteHUDLifecycleTests {
  init() { _ = NSApplication.shared }

  private func controller() -> HUDWindowController {
    let settings = SettingsManager(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      launchAtLoginService: TestLaunchAtLoginService()
    )
    let hud = HUDWindowController(
      settingsManager: settings, mediaKeyStatus: MediaKeyStatus(),
      popupVisibility: PopupVisibilityService()
    )
    hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }
    hud.fullscreenProvider = { false }
    return hud
  }

  @Test("Fullscreen suppression is preserved independently of the popup/timer fixtures")
  func fullscreenSuppression() {
    let hud = controller()
    defer { hud.shutdown() }
    hud.fullscreenProvider = { true }
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Fixture")
    #expect(hud.showCallCount == 1)
    #expect(!hud.showDidUpdatePanel)
    #expect(!hud.isVisible)
  }

  @Test("The actual panel is presented and then hidden by the deadline")
  func panelAutoHide() async throws {
    let hud = controller()
    defer { hud.shutdown() }
    hud.hideDelayOverride = .milliseconds(20)
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Fixture")
    #expect(hud.isVisible)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!hud.isVisible)
  }

  @Test("A canceled hide task cannot hide a newer presentation")
  func timerResetAndShutdown() async throws {
    let hud = controller()
    defer { hud.shutdown() }
    hud.hideDelayOverride = .milliseconds(20)
    hud.show(sliderFraction: 0.2, mute: false, deviceName: "Fixture")
    hud.hideDelayOverride = .seconds(1)
    hud.show(sliderFraction: 0.8, mute: false, deviceName: "Fixture")
    try await Task.sleep(for: .milliseconds(100))
    #expect(hud.isVisible)
    hud.shutdown()
    #expect(!hud.isVisible)
  }
}
