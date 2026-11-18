// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune (FineTuneTests/{MenuBarIconImageSizeTests,
// MenuBarPopupControllerTests,HUDWindowControllerTests,HUDDeviceNameTests}.swift)
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51

import AppKit
import AudioToolbox
import FineTuneDomain
import FineTunePlatform
import Foundation
import SwiftUI
import Testing

@testable import FineTune

private final class RenderedCompatLaunchAtLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
private func makeRenderedSettingsManager() -> SettingsManager {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  return SettingsManager(directory: dir, launchAtLoginService: RenderedCompatLaunchAtLoginService())
}

// MARK: - MenuBarIconImage Rendering

@Suite("Upstream MenuBarIconImage AppKit Compatibility")
@MainActor
struct UpstreamMenuBarIconImageCompatibilityTests {

  @Test("Canvas size is fixed at 22x18")
  func canvasSize() {
    #expect(MenuBarIconImage.canvasSize == NSSize(width: 22, height: 18))
  }

  @Test("System symbol icon renders to template NSImage sized 22x18")
  func systemSymbolRendersAtCanvasSize() throws {
    let image = try #require(MenuBarIconImage.systemSymbol("speaker.wave.2.fill").nsImage())
    #expect(image.size == MenuBarIconImage.canvasSize)
    #expect(image.isTemplate)
  }

  @Test("Default MenuBarIcon asset renders to template NSImage sized 22x18")
  func defaultAssetRendersAtCanvasSize() throws {
    let image = try #require(MenuBarIconImage.asset("MenuBarIcon").nsImage())
    #expect(image.size == MenuBarIconImage.canvasSize)
    #expect(image.isTemplate)
  }
}

// MARK: - MenuBarPopupController & OwnedPopover

@Suite("Upstream MenuBarPopupController AppKit Compatibility")
@MainActor
struct UpstreamMenuBarPopupControllerCompatibilityTests {

  @Test(
    "Attached status item overrides discovery and toggles synchronously without posting mouse events"
  )
  func attachOverridesDiscoveryAndToggles() {
    var postedEvents = 0
    let controller = MenuBarPopupController(
      accessibilityTitle: "NonExistentTitle",
      eventPoster: { _ in postedEvents += 1 }
    )
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }

    var toggleInvocations = 0
    controller.attach(statusItem: statusItem) {
      toggleInvocations += 1
    }

    #expect(controller.findStatusItem() === statusItem)
    controller.toggle()
    #expect(toggleInvocations == 1)
    #expect(postedEvents == 0)
  }

  @Test("Without owned status item, nonexistent title returns nil and toggle is a safe no-op")
  func nonexistentTitleIsNoOp() {
    var postedEvents = 0
    let controller = MenuBarPopupController(
      accessibilityTitle: "FineTuneTestDoesNotExist-\(UUID().uuidString)",
      eventPoster: { _ in postedEvents += 1 }
    )
    #expect(controller.findStatusItem() == nil)
    controller.toggle()
    #expect(postedEvents == 0)
  }

  @Test("MenuBarPopupContentController measures hosted SwiftUI view inside NSPopover")
  func makePopoverMeasuresContent() {
    let popover = MenuBarPresentation.makePopover(
      content: Text("FineTune Contract").frame(width: 240, height: 120)
    )
    #expect(popover.contentViewController != nil)
    #expect(popover.contentSize.width >= 200)
    #expect(popover.contentSize.height >= 100)
  }
}

// MARK: - HUDWindowController & HUD Smoke Tests

@Suite("Upstream HUDWindowController AppKit Compatibility")
@MainActor
struct UpstreamHUDWindowControllerCompatibilityTests {

  @Test("Suppressed when popup is visible or foreground app is fullscreen")
  func suppressedWhenPopupOrFullscreen() {
    let settings = makeRenderedSettingsManager()
    let popup = PopupVisibilityService()
    popup.isVisible = true
    let hud = HUDWindowController(
      settingsManager: settings,
      mediaKeyStatus: MediaKeyStatus(),
      popupVisibility: popup
    )
    defer { hud.shutdown() }

    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Built-in")
    #expect(hud.showCallCount == 1)
    #expect(!hud.showDidUpdatePanel)
    #expect(!hud.isVisible)

    popup.isVisible = false
    hud.fullscreenProvider = { true }
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Built-in")
    #expect(hud.showCallCount == 2)
    #expect(!hud.showDidUpdatePanel)
    #expect(!hud.isVisible)
  }

  @Test("Shows HUD panel for tahoe, classic, and per-app states and hides cleanly on shutdown")
  func showsAndHidesHUDVariants() {
    let settings = makeRenderedSettingsManager()
    let hud = HUDWindowController(
      settingsManager: settings,
      mediaKeyStatus: MediaKeyStatus(),
      popupVisibility: PopupVisibilityService()
    )
    hud.fullscreenProvider = { false }
    defer { hud.shutdown() }

    hud.show(sliderFraction: 0.4, mute: false, deviceName: "Studio Display Speakers")
    #expect(hud.showDidUpdatePanel)
    #expect(hud.isVisible)

    var appSettings = settings.appSettings
    appSettings.hudStyle = .classic
    settings.updateAppSettings(appSettings)
    hud.show(sliderFraction: 0.8, mute: true, deviceName: "AirPods Pro")
    #expect(hud.showDidUpdatePanel)
    #expect(hud.isVisible)

    let app = AudioApp(
      id: 901,
      processObjectIDs: [1],
      name: "Spotify",
      icon: NSImage(size: NSSize(width: 16, height: 16)),
      bundleID: "com.spotify.client"
    )
    hud.showPerAppVolumeHUD(app: app, sliderFraction: 0.65)
    #expect(hud.isVisible)
    hud.showPerAppMuteHUD(app: app, isMuted: true)
    #expect(hud.isVisible)
    hud.showPerAppNotControlledHUD(displayName: "Finder", bundleID: "com.apple.finder", icon: nil)
    #expect(hud.isVisible)

    hud.hide()
    #expect(!hud.isVisible)
  }
}
