import AppKit
import FineTuneDomain
import FineTunePlatform
import Foundation
import SwiftUI
import Testing

@testable import FineTune

private final class IndependentLaunchAtLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
private final class IndependentHUDDeadlineClock {
  private var waiters: [CheckedContinuation<Void, any Error>] = []
  var sleepCount = 0

  var backendClock: DeviceBackendClock {
    DeviceBackendClock { [weak self] _ in
      try await withCheckedThrowingContinuation { continuation in
        Task { @MainActor in
          guard let self else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.sleepCount += 1
          self.waiters.append(continuation)
        }
      }
    }
  }

  func waitForSleepCount(_ expected: Int) async {
    for _ in 0..<50 where sleepCount < expected {
      await Task.yield()
    }
  }

  /// Deadline firing resumes the sleeping hide task on the shared MainActor
  /// executor, so the hide needs a bounded condition wait instead of a fixed
  /// hop count before its effect is observable.
  func waitUntilHidden(_ hud: HUDWindowController) async {
    for _ in 0..<50 where hud.isVisible {
      await Task.yield()
    }
  }

  func fireNext() {
    guard !waiters.isEmpty else { return }
    let next = waiters.removeFirst()
    next.resume()
  }

  func cancelAll() {
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume(throwing: CancellationError())
    }
  }
}

@Suite("Independent AppKit Bridge Compatibility")
@MainActor
struct IndependentAppKitCompatibilityTests {

  @Test(
    "WindowAppearanceBridge attaches to NSWindow, synchronizes appearance, and clears observer on detach"
  )
  func appearanceBridgeLifecycle() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let hostView = WindowAppearanceBridge.AppearanceHostView(
      frame: NSRect(x: 0, y: 0, width: 50, height: 50))
    hostView.appearanceOverride = NSAppearance(named: .darkAqua)
    window.contentView?.addSubview(hostView)
    hostView.synchronize()
    #expect(window.appearance?.name == .darkAqua)

    hostView.appearanceOverride = NSAppearance(named: .aqua)
    hostView.synchronize()
    #expect(window.appearance?.name == .aqua)

    hostView.appearanceOverride = nil
    hostView.synchronize()
    #expect(window.appearance == NSApplication.shared.effectiveAppearance)

    hostView.removeFromSuperview()
    window.close()
  }

  @Test("DeviceIconPicker lays out inside NSHostingView with non-zero rendered bounds")
  func deviceIconPickerRendering() {
    let picker = DeviceIconPicker(
      deviceName: "Studio Display",
      transport: .displayPort,
      automaticSymbol: "display",
      automaticIsSymbol: true,
      currentOverride: nil,
      onSelect: { _ in }
    )
    let hosting = NSHostingView(rootView: picker)
    hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
    hosting.layoutSubtreeIfNeeded()
    let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    #expect(rep != nil)
    #expect(hosting.fittingSize.width > 0)
    #expect(hosting.fittingSize.height > 0)
  }

  @Test(
    "The Settings window hosts SwiftUI in a contentView NSHostingView with the fitted size",
    arguments: [NSSize(width: 720, height: 560)]
  )
  func settingsWindowHosting(fitted: NSSize) throws {
    let window = SettingsWindowFactory.make(
      content: Text("Settings").frame(width: fitted.width, height: fitted.height))
    defer { window.close() }
    // The tab row is ordinary content below the title bar, not title-bar toolbar content.
    #expect(window.contentViewController == nil)
    let content = try #require(window.contentView)
    #expect(String(describing: type(of: content)).hasPrefix("NSHostingView"))
    #expect(content.frame.size == fitted)
    #expect(window.backgroundColor == .windowBackgroundColor)
    #expect(!window.isReleasedWhenClosed)
  }

  @Test(
    "MenuBarIconImage boundary cases return nil for nonexistent assets/symbols and 22x18 bitmaps for valid inputs"
  )
  func menuBarIconRendererBoundary() {
    #expect(MenuBarIconImage.systemSymbol("nonexistent.symbol.name.12345").nsImage() == nil)
    #expect(MenuBarIconImage.asset("NonExistentAssetName12345").nsImage() == nil)

    for candidate in [
      MenuBarIconImage.asset("MenuBarIcon"),
      MenuBarIconImage.systemSymbol("speaker.slash.fill"),
      MenuBarIconImage.systemSymbol("airpodspro"),
    ] {
      let img = candidate.nsImage()
      #expect(img != nil)
      #expect(img?.size == NSSize(width: 22, height: 18))
      #expect(img?.isTemplate == true)
    }
  }

  @Test("MenuBarPresentation wires owned NSStatusItem action through MenuBarPopupController")
  func ownedStatusBarControllerWiring() throws {
    let visibility = PopupVisibilityService()
    var willShowCount = 0
    let presentation = MenuBarPresentation(
      visibility: visibility,
      willShow: { willShowCount += 1 },
      content: { Text("Owned").frame(width: 120, height: 80) }
    )
    defer { presentation.shutdown() }

    let button = try #require(presentation.statusItem.button)
    #expect(button.accessibilityTitle() == "FineTune-Rewrite")
    #expect(presentation.popupController.findStatusItem() === presentation.statusItem)

    presentation.popupController.toggle()
    #expect(willShowCount == 1)
    presentation.shutdown()
    #expect(!visibility.isVisible)
  }

  @Test(
    "HUDWindowController deadline timer hides panel when fired and resets cleanly across rapid shows"
  )
  func rewriteHUDDeadlineLifecycle() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(
      directory: dir, launchAtLoginService: IndependentLaunchAtLoginService())
    let clock = IndependentHUDDeadlineClock()
    let hud = HUDWindowController(
      settingsManager: settings,
      mediaKeyStatus: MediaKeyStatus(),
      popupVisibility: PopupVisibilityService(),
      clock: clock.backendClock
    )
    hud.fullscreenProvider = { false }
    defer {
      clock.cancelAll()
      hud.shutdown()
    }

    hud.show(sliderFraction: 0.3, mute: false, deviceName: "Desk")
    await clock.waitForSleepCount(1)
    #expect(hud.isVisible)
    #expect(clock.sleepCount == 1)

    hud.show(sliderFraction: 0.6, mute: false, deviceName: "Desk")
    await clock.waitForSleepCount(2)
    #expect(hud.isVisible)
    #expect(clock.sleepCount == 2)

    clock.fireNext()
    await clock.waitUntilHidden(hud)
    clock.fireNext()
    await clock.waitUntilHidden(hud)
    #expect(!hud.isVisible)
  }
}
