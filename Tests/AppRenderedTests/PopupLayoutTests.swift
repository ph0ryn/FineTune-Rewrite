// Production SwiftUI/AppKit components only, with explicit fake actions.
// Fitted-view unit fixtures stay offscreen. Native lifecycle fixtures briefly show only their own
// anchor window and popover, always clean up, and never start application services or permissions.
// The offscreen SwiftUI host exposes no NSAccessibility text tree, so Vision OCR on owned view
// bitmaps checks rendered copy visibility. Control frames/actions use native proxies; narrow pixel
// probes cover drawn selection/slider styling. The maximum-value screenshot is limited to the
// fixture's own window via the current-process capture API; no desktop or foreign window is read.
// A framework-owned popover transition that misses its bound throws instead of passing silently.
import AppKit
import FineTuneDomain
import FineTunePlatform
import ScreenCaptureKit
import SwiftUI
import Testing
import Vision

@testable import FineTune

@Suite("Non-scrolling production popup layout")
@MainActor
struct PopupLayoutTests {
  @Test("The actual mixer has no vertical scroll container")
  func noVerticalScrollContainer() {
    let source = MixerTestSource()
    let fixture = PopupLayoutFixture(source: source)
    #expect(!descendants(of: fixture.host).contains { $0 is NSScrollView })
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test("Intrinsic height adds 40pt for every compact application row without a fixed viewport")
  func intrinsicHeightIncludesAllRows() {
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 1)
    let single = PopupLayoutFixture(source: source)
    let singleHeight = single.controller.preferredContentSize.height
    source.snapshot.apps = popupApps(count: 6)
    let populated = PopupLayoutFixture(source: source)
    #expect(abs(populated.controller.preferredContentSize.height - singleHeight - 5 * 40) <= 0.5)
    #expect(source.events.isEmpty)
  }

  @Test("The final application and its route control are inside the fitted production view")
  func lastApplicationIsVisible() throws {
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 4)
    source.snapshot.apps[3].isFollowingDefault = false
    source.snapshot.apps[3].selectedDeviceUIDs = ["output-uid"]
    let fixture = PopupLayoutFixture(source: source)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try writePNG(
        of: fixture.host, to: destination.appendingPathComponent("last-application-visible.png"))
    }
    let image = try bitmapImage(in: fixture.host)
    let renderedText = try recognizedText(in: image)
    #expect(renderedText.contains { $0.text.contains("Player 1") })
    let lastGlyph = try #require(renderedText.first { $0.text.contains("Player 4") })
    let routeGlyph = try #require(
      renderedText.first {
        $0.text.contains("Output") && $0.bounds.maxY < lastGlyph.bounds.minY
          && $0.bounds.minY > 0
      })
    for item in [lastGlyph, routeGlyph] {
      #expect(item.bounds.width > 0 && item.bounds.height > 0)
      #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(item.bounds))
    }
    let semantics = MixerPopupSemantics(snapshot: source.snapshot, bindings: source.bindings)
    #expect(semantics.sectionHeader == "APPS")
    #expect(semantics.apps.count == 4)
    // The popup body renders this same production list: the final app's name, its nondefault
    // subtitle and the APPS section header.
    let lastApp = try #require(semantics.apps.last)
    #expect(lastApp.id == "com.example.player-4")
    #expect(lastApp.name == "Player 4")
    let subtitle = try #require(
      MixerAppRowPresentation(app: lastApp, bindings: source.bindings).subtitle)
    #expect(subtitle.contains("Output"))
    let host = try fixture.hostingController().view
    let last = try #require(fixture.editableFieldFrames(in: host).last)
    #expect(host.bounds.contains(last))
    let trailingControls = nativeButtonProxyFrames(in: host).filter {
      $0.minY < last.maxY && $0.maxY > last.minY && $0.minX >= last.maxX
    }
    #expect(
      trailingControls.count == 3,
      "The final row retains its boost, route and EQ controls after the percentage field")
    #expect(trailingControls.allSatisfy { host.bounds.contains($0) })
    let point = CGPoint(
      x: last.minX - DesignTokens.Spacing.sm - DesignTokens.Dimensions.sliderWidth * 0.4,
      y: last.midY)
    #expect(host.bounds.contains(point))
    try fixture.sendClick(point, in: host)
    #expect(source.events == ["app-volume"])
    #expect(source.lastAppID == lastApp.id)
    #expect(source.profileSource.events.isEmpty)
  }

  @Test("Capture recovery controls remain visible and rendering does not invoke them")
  func captureRecoveryIsExplicit() throws {
    func make(_ action: MixerCaptureNotice.Action?) -> (MixerTestSource, PopupLayoutFixture) {
      let source = MixerTestSource()
      source.snapshot.captureNotice = MixerCaptureNotice(
        message: "Capture needs an explicit retry.", action: action)
      return (source, PopupLayoutFixture(source: source))
    }
    let (baselineSource, baseline) = make(nil)
    let (retrySource, retry) = make(.retryCapture)
    let (settingsSource, settings) = make(.openSettings)
    let (permissionSource, permission) = make(.requestPermission)
    let baselineHeight = baseline.controller.preferredContentSize.height
    let retryHeight = retry.controller.preferredContentSize.height
    let settingsHeight = settings.controller.preferredContentSize.height
    let permissionHeight = permission.controller.preferredContentSize.height
    let baselineText = try recognizedText(in: bitmapImage(in: baseline.host))
    let retryText = try recognizedText(in: bitmapImage(in: retry.host))
    let settingsText = try recognizedText(in: bitmapImage(in: settings.host))
    let permissionText = try recognizedText(in: bitmapImage(in: permission.host))
    #expect(baselineText.contains { $0.text.contains("Capture needs an explicit retry") })
    #expect(retryText.contains { $0.text.contains("Capture needs an explicit retry") })
    #expect(!retryText.contains { $0.text.localizedCaseInsensitiveContains("Retry Audio") })
    let settingsLabel = try #require(
      settingsText.first { $0.text.contains("Open System Settings") })
    #expect(settingsLabel.bounds.width > 0 && settingsLabel.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(settingsLabel.bounds))
    let permissionLabel = try #require(
      permissionText.first { $0.text.contains("Allow System Audio") })
    #expect(permissionLabel.bounds.width > 0 && permissionLabel.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(permissionLabel.bounds))
    let baselineSemantics = MixerPopupSemantics(
      snapshot: baselineSource.snapshot, bindings: baselineSource.bindings)
    let retrySemantics = MixerPopupSemantics(
      snapshot: retrySource.snapshot, bindings: retrySource.bindings)
    let settingsSemantics = MixerPopupSemantics(
      snapshot: settingsSource.snapshot, bindings: settingsSource.bindings)
    let permissionSemantics = MixerPopupSemantics(
      snapshot: permissionSource.snapshot, bindings: permissionSource.bindings)
    // The rendered copy is the production projection: the retry action remains the header icon
    // only, while Open System Settings is the one inline button.
    #expect(baselineSemantics.captureNotice?.message == "Capture needs an explicit retry.")
    #expect(baselineSemantics.captureNotice?.actionLabel == nil)
    #expect(retrySemantics.captureNotice?.actionLabel == nil)
    #expect(settingsSemantics.captureNotice?.actionLabel == "Open System Settings")
    #expect(permissionSemantics.captureNotice?.actionLabel == "Allow System Audio")
    #expect(abs(retryHeight - baselineHeight) < 0.5)
    #expect(settingsHeight > baselineHeight + 1)
    #expect(permissionHeight > baselineHeight + 1)

    // Click the actual rendered inline button frame; it must reach only the capture-settings action.
    let host = try settings.hostingController().view
    try settings.showForPointerInput()
    let firstField = try #require(settings.editableFieldFrames(in: host).first)
    let inline = nativeButtonProxyFrames(in: host, minimumWidth: 80).filter {
      let aboveDeviceRow =
        host.isFlipped ? $0.midY < firstField.midY - 10 : $0.midY > firstField.midY + 10
      return aboveDeviceRow && $0.height <= 30 && $0.width <= 300
    }
    #expect(inline.count == 1, "The inline Open System Settings button renders once")
    let button = try #require(inline.first)
    try settings.sendClick(CGPoint(x: button.midX, y: button.midY), in: host)
    #expect(settingsSource.events == ["capture-settings"])
    #expect(baselineSource.events.isEmpty && retrySource.events.isEmpty)
    #expect(settingsSource.profileSource.events.isEmpty)

    let permissionHost = try permission.hostingController().view
    try permission.showForPointerInput()
    let permissionFirstField = try #require(
      permission.editableFieldFrames(in: permissionHost).first)
    let permissionInline = nativeButtonProxyFrames(in: permissionHost, minimumWidth: 80).filter {
      let aboveDeviceRow =
        permissionHost.isFlipped
        ? $0.midY < permissionFirstField.midY - 10 : $0.midY > permissionFirstField.midY + 10
      return aboveDeviceRow && $0.height <= 30 && $0.width <= 300
    }
    #expect(permissionInline.count == 1, "The inline Allow System Audio button renders once")
    let permissionButton = try #require(permissionInline.first)
    try permission.sendClick(
      CGPoint(x: permissionButton.midX, y: permissionButton.midY), in: permissionHost)
    #expect(permissionSource.events == ["capture-request"])
    #expect(permissionSource.profileSource.events.isEmpty)
  }

  @Test("Quit and its shortcut stay visible in the original footer below all application rows")
  func quitIsVisible() throws {
    // The exact footer copy is asserted in AppPresentationContractTests; the rendered footer below
    // keeps the visible Quit glyph and its click.
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 4)
    let fixture = PopupLayoutFixture(source: source)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try writePNG(of: fixture.host, to: destination.appendingPathComponent("quit-visible.png"))
    }
    let host = try fixture.hostingController().view
    let renderedText = try recognizedText(in: bitmapImage(in: fixture.host))
    #expect(renderedText.contains { $0.text.contains("Player 1") })
    let quitGlyph = try #require(renderedText.first { $0.text.contains("Quit") })
    #expect(quitGlyph.bounds.width > 0 && quitGlyph.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(quitGlyph.bounds))
    let lastGlyph = try #require(renderedText.first { $0.text.contains("Player 4") })
    #expect(quitGlyph.bounds.maxY < lastGlyph.bounds.minY)
    #expect(quitGlyph.bounds.midY < 0.15)
    let last = try #require(fixture.editableFieldFrames(in: host).last)
    #expect(host.bounds.contains(last))
    // The footer button's actual rendered proxy is the bottom-most wide control, below the last
    // app's percentage column. No coordinate is recomputed from a formula.
    let buttons = nativeButtonProxyFrames(in: host, minimumWidth: 40).filter {
      $0.height <= 30 && $0.width <= 200
    }
    let quit = try #require(
      host.isFlipped
        ? buttons.max(by: { $0.midY < $1.midY })
        : buttons.min(by: { $0.midY < $1.midY }))
    #expect(host.bounds.contains(quit))
    if host.isFlipped {
      #expect(quit.midY > last.maxY, "The footer button is below the final application row")
    } else {
      #expect(quit.midY < last.minY, "The footer button is below the final application row")
    }
    try fixture.sendClick(CGPoint(x: quit.midX, y: quit.midY), in: host)
    #expect(source.events == ["quit"])
    #expect(source.profileSource.events.isEmpty)
  }

  @Test("The own offscreen window's Quit key equivalent invokes only its required fake action")
  func quitKeyEquivalentUsesRequiredAction() throws {
    let source = MixerTestSource()
    let fixture = PopupLayoutFixture(source: source)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: fixture.window.windowNumber, context: nil, characters: "q",
        charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
    // NSWindow dispatches the hosting view's key equivalent, including the fake Button action,
    // before returning.
    let handled = fixture.window.performKeyEquivalent(with: event)
    #expect(handled)
    #expect(source.events == ["quit"])
  }

  @Test("The production factory assigns its initial fitted size before presentation")
  func initialPopoverSizeIsResolved() throws {
    let source = MixerTestSource()
    source.snapshot.apps = []
    let popover = MenuBarPresentation.makePopover(content: popupView(source))
    let controller = try #require(popover.contentViewController)
    #expect(controller.preferredContentSize.height > 0)
    #expect(popover.contentSize == controller.preferredContentSize)
    #expect(controller.view.frame.size == controller.preferredContentSize)
    #expect(!popover.isShown && source.events.isEmpty)
    // Natural changes are exercised by the actual shown-popup lifecycle suite below, not injection.
  }

  @Test("Menu-bar production content uses native glass with the hosting view inside contentView")
  func nativeGlassContainsActualContent() throws {
    _ = NSApplication.shared
    let source = MixerTestSource()
    let popover = MenuBarPresentation.makePopover(content: popupView(source))
    let controller = try #require(popover.contentViewController)
    controller.loadViewIfNeeded()
    if #available(macOS 26, *) {
      let usesNativeGlass = controller.view is NSGlassEffectView
      #expect(usesNativeGlass)
      guard let glass = controller.view as? NSGlassEffectView else { return }
      let content = try #require(glass.contentView)
      #expect(content is NSHostingView<AnyView>)
      #expect(!content.isOpaque)
      #expect(glass.style == .regular)
      #expect(glass.tintColor == nil)
      #expect(controller.preferredContentSize.height > 0)
    } else {
      #expect(controller.view is NSHostingView<AnyView>)
    }
    #expect(source.events.isEmpty)
  }

  @Test("Opt-in evidence renders only fake production popup content, never the desktop")
  func fakeContentEvidence() throws {
    guard let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"]
    else {
      return
    }
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot.apps = popupApps(count: 4)
    source.snapshot.captureNotice = MixerCaptureNotice(
      message: "Application metadata has an invalid or duplicate process identity.", action: nil)
    let fixture = PopupLayoutFixture(source: source)
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try writePNG(of: fixture.host, to: destination.appendingPathComponent("fake-popup.png"))
    print("Fake popup fitted size: \(fixture.controller.preferredContentSize)")

    // Same content without native glass, for bitmap/vibrancy diagnosis only; not product styling.
    let plain = NSHostingView(
      rootView: popupView(source).background(Color(nsColor: .windowBackgroundColor)))
    let plainWindow = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: plain.fittingSize),
      styleMask: .borderless, backing: .buffered, defer: false)
    plainWindow.isReleasedWhenClosed = false
    plainWindow.contentView = plain
    plain.layoutSubtreeIfNeeded()
    try writePNG(of: plain, to: destination.appendingPathComponent("fake-popup-plain.png"))
    defer { plainWindow.close() }

    let normal = MixerTestSource()
    normal.snapshot.settings.appearance = .light
    normal.snapshot.apps = popupApps(count: 4)
    let normalFixture = PopupLayoutFixture(source: normal)
    try writePNG(
      of: normalFixture.host, to: destination.appendingPathComponent("fake-popup-normal.png"))
    #expect(!normalFixture.window.isVisible && normal.events.isEmpty)

    source.snapshot.apps = popupApps(count: 6)
    var secondOutput = source.snapshot.outputDevices[0]
    secondOutput.device = AudioDevice(
      id: 3, uid: "second-output", name: "Second Output", icon: nil, supportsAutoEQ: false)
    secondOutput.isDefault = false
    source.snapshot.outputDevices.append(secondOutput)
    let expanded = MixerView(
      read: { source.snapshot }, actions: source.actions, profiles: source.profileSource.interface,
      quit: { source.events.append("quit") },
      initialExpandedAppID: source.snapshot.apps[0].id)
    let expandedPopover = MenuBarPresentation.makePopover(content: expanded)
    let expandedController = try #require(expandedPopover.contentViewController)
    let screen = try #require(NSScreen.main)
    print(
      "Six-app, two-output, expanded-EQ ideal: \(expandedController.preferredContentSize); visible screen: \(screen.visibleFrame)"
    )
    #expect(!fixture.window.isVisible && !plainWindow.isVisible && !expandedPopover.isShown)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }
}

@Suite("Production popup native lifecycle", .serialized)
@MainActor
struct PopupNativeLifecycleTests {
  @Test("App warnings stay out of reorder mode and return on exit without losing updates")
  func editingHidesAppWarningsUntilExit() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot.apps = popupApps(count: 3)
    source.snapshot.apps[0].isPinned = true
    source.snapshot.apps[2].isActive = false
    var hiddenApp = popupApps(count: 1)[0]
    hiddenApp.id = "com.example.hidden"
    hiddenApp.name = "Hidden"
    hiddenApp.isIgnored = true
    source.snapshot.apps.append(hiddenApp)
    source.snapshot.captureNotice = nil
    source.snapshot.error = "Unable to save settings."
    source.snapshot.apps[0].routeStatus = "Current audio route failed"
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    fixture.layout()
    let host = try fixture.hostingController().view
    func editPoint() -> CGPoint {
      let padding = source.snapshot.settings.popupSize.dimensions.contentPadding
      let target = DesignTokens.Dimensions.minTouchTarget
      let top = padding + target / 2
      return CGPoint(
        x: host.bounds.maxX - padding - target / 2 - 2 * (target + DesignTokens.Spacing.sm),
        y: host.isFlipped ? top : host.bounds.maxY - top)
    }
    func text() throws -> String {
      try recognizedText(
        in: bitmapImage(in: fixture.controller.view),
        opaqueBackground: CGColor(gray: 1, alpha: 1)
      ).map(\.text).joined(separator: "\n")
    }

    let withWarning = try fixture.checkVisible(
      phase: "normal", markers: ["Quit", "Current audio route", "Unable to save settings"])
    #expect(try text().contains("Current audio route"))
    source.snapshot.apps[0].routeStatus = nil
    fixture.layout()
    let withoutWarning = try fixture.checkVisible(
      phase: "normal-no-warning", markers: ["Quit", "Unable to save settings"])
    #expect(try !text().contains("Current audio route"))
    #expect(withWarning > withoutWarning, "A current route warning occupies its own visible row")

    source.snapshot.apps[0].routeStatus = "Current audio route failed"
    fixture.layout()
    try fixture.sendClick(editPoint(), in: host)
    fixture.layout()
    _ = try fixture.checkVisible(phase: "editing", markers: ["Quit", "Unable to save settings"])
    let editingText = try text()
    #expect(!editingText.contains("Current audio route"))
    #expect(editingText.contains("Unable to save settings"))
    let editingSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings, editing: true)
    #expect(
      editingSemantics.apps.map(\.id) == [
        "com.example.player-1", "com.example.player-2", "com.example.player-3",
      ])
    #expect(editingSemantics.ignoredApps.map(\.id) == [hiddenApp.id])

    let popupControls = nativeButtonProxyFrames(in: host)
    let gridControls = popupControls.filter { frame in
      let belowEditButton = host.isFlipped ? frame.midY > editPoint().y : frame.midY < editPoint().y
      return belowEditButton && frame.width <= 30 && frame.height <= 30
    }
    let renderedRows = renderedControlRows(gridControls, isFlipped: host.isFlipped)
    let appRows = Array(renderedRows.suffix(2))
    #expect(
      appRows.map(\.count) == [2, 1],
      "MixerView renders the inactive edit-only row and separate ignored row; rows=\(appRows)"
    )
    try #require(appRows.count == 2)
    let inactivePin = try #require(appRows[0].first)
    try fixture.sendClick(CGPoint(x: inactivePin.midX, y: inactivePin.midY), in: host)
    #expect(source.events == ["pin"])
    #expect(source.lastAppID == "com.example.player-3" && source.lastBool == true)
    source.events.removeAll()
    let hiddenEye = try #require(appRows[1].first)
    try fixture.sendClick(CGPoint(x: hiddenEye.midX, y: hiddenEye.midY), in: host)
    #expect(source.events == ["ignore"])
    #expect(source.lastAppID == hiddenApp.id && source.lastBool == false)
    source.events.removeAll()

    source.snapshot.apps[0].routeStatus = "Current audio cleanup failed"
    fixture.layout()
    let editingUpdated = try fixture.checkVisible(
      phase: "editing-updated", markers: ["Quit", "Unable to save settings"])
    let updatedText = try text()
    #expect(!updatedText.contains("Current audio cleanup"))
    #expect(!updatedText.contains("Current audio route"))
    #expect(updatedText.contains("Unable to save settings"))
    source.snapshot.apps[0].routeStatus = nil
    fixture.layout()
    let editingNoWarning = try fixture.checkVisible(
      phase: "editing-no-warning", markers: ["Quit", "Unable to save settings"])
    #expect(try !text().contains("Current audio cleanup"))
    #expect(try text().contains("Unable to save settings"))
    #expect(
      abs(editingUpdated - editingNoWarning) < 0.5,
      "Reorder mode hides current app warnings instead of duplicating them")

    source.snapshot.apps[0].routeStatus = "Current audio cleanup failed"
    source.snapshot.error = nil
    fixture.layout()
    let editingNoError = try fixture.checkVisible(
      phase: "editing-no-error", markers: ["Quit", "Player 1", "APPS"])
    let noErrorText = try text()
    #expect(!noErrorText.contains("Current audio cleanup"))
    #expect(!noErrorText.contains("Unable to save settings"))
    #expect(
      editingUpdated > editingNoError, "An independent save error remains visible while editing")

    source.snapshot.error = "Unable to save settings."
    fixture.layout()
    try fixture.sendClick(editPoint(), in: host)
    fixture.layout()
    let afterExit = try fixture.checkVisible(
      phase: "after", markers: ["Quit", "Current audio cleanup", "Unable to save settings"])
    let afterExitText = try text()
    #expect(afterExitText.contains("Current audio cleanup"))
    #expect(!afterExitText.contains("Current audio route"))
    #expect(afterExitText.contains("Unable to save settings"))
    let updatedStatus = source.snapshot.apps[0].routeStatus
    #expect(updatedStatus == "Current audio cleanup failed")
    source.snapshot.apps[0].routeStatus = nil
    fixture.layout()
    let afterExitNoWarning = try fixture.checkVisible(
      phase: "after-no-warning", markers: ["Quit", "Unable to save settings"])
    #expect(try !text().contains("Current audio cleanup"))
    #expect(
      afterExit > afterExitNoWarning,
      "Leaving reorder mode shows the latest observed warning instead of the stale one")
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test(
    "Retry Audio is always an icon beside reorder and invokes only explicit capture retry",
    arguments: MenuBarPopupSize.allCases)
  func headerRetryIsAlwaysAvailable(size: MenuBarPopupSize) async throws {
    let source = MixerTestSource()
    source.snapshot.settings.popupSize = size
    source.snapshot.captureNotice = nil
    source.snapshot.error = nil
    // A current route warning is visible before reorder mode; the reorder control's native priority
    // field observed below, not the popup height, proves the edit click toggled the popup.
    source.snapshot.apps[0].isActive = true
    source.snapshot.apps[0].routeStatus = "Current audio route failed"
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    fixture.layout()
    let host = try fixture.hostingController().view
    let padding = source.snapshot.settings.popupSize.dimensions.contentPadding
    let target = DesignTokens.Dimensions.minTouchTarget
    let step = target + DesignTokens.Spacing.sm
    let top = padding + target / 2
    let retryPoint = CGPoint(
      x: host.bounds.maxX - padding - target / 2 - step,
      y: host.isFlipped ? top : host.bounds.maxY - top)
    #expect(source.events.isEmpty)
    try fixture.sendClick(retryPoint, in: host)
    #expect(source.events == ["capture-request"])
    try fixture.checkVisible(
      phase: "normal-warning", markers: ["APPS"])
    // Reorder mode renders a native priority field for every device; its 1-based value is only
    // present after the edit click and does not depend on the size-dependent height changes that
    // the reorder chrome (priority/icon/pin/visibility controls, Bluetooth section) causes.
    #expect(
      !fixture.editableFields(in: host).contains { $0.stringValue == "1" },
      "Normal mode renders no device priority reorder control")
    // Reordering must not hide or repurpose the neighboring recovery control.
    try fixture.sendClick(CGPoint(x: retryPoint.x - step, y: retryPoint.y), in: host)
    fixture.layout()
    try fixture.checkVisible(
      phase: "reorder", markers: ["APPS"])
    #expect(
      fixture.editableFields(in: host).contains { $0.stringValue == "1" },
      "The edit click entered reorder mode and rendered the device priority reorder control")
    let editingRetryPoint = CGPoint(
      x: retryPoint.x, y: host.isFlipped ? top : host.bounds.maxY - top)
    try fixture.sendClick(editingRetryPoint, in: host)
    #expect(source.events == ["capture-request", "capture-request"])
  }

  @Test(
    "A shown production popup naturally follows cold, warm, subtitle, shrink and reopen content")
  func naturalShownContentChanges() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    let warm = warmPopupSnapshot(source)
    var cold = warm
    cold.apps = []
    cold.outputDevices = []
    cold.inputDevices = []
    source.snapshot = cold
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    // Production constructs the cold controller before discovery finishes while it is still hidden.
    source.snapshot = warm
    fixture.layout()
    fixture.show()
    fixture.layout()
    let warmOnFirstOpen = try fixture.checkVisible(
      phase: "hidden-warm-first-open", markers: ["Quit", "First Output", "Player 4", "APPS"])
    let warmSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings)
    #expect(warmSemantics.sectionHeader == "APPS")
    #expect(warmSemantics.outputName == "First Output")
    #expect(warmSemantics.inputName == "Input")
    #expect(warmSemantics.apps.count == 4)
    #expect(warmSemantics.apps.last?.name == "Player 4")
    #expect(warmSemantics.emptyState == nil)
    source.snapshot = cold
    fixture.layout()
    let coldHeight = try fixture.checkVisible(
      phase: "cold", markers: ["Quit", "No apps playing audio"])
    let coldSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings)
    #expect(coldSemantics.sectionHeader == "APPS")
    #expect(coldSemantics.emptyState == "No apps playing audio")
    #expect(coldSemantics.apps.isEmpty)
    #expect(coldSemantics.outputName == "No Output")

    var ignoredOnly = cold
    ignoredOnly.apps = popupApps(count: 2).map { app in
      var ignored = app
      ignored.isActive = false
      ignored.isIgnored = true
      return ignored
    }
    source.snapshot = ignoredOnly
    fixture.layout()
    let ignoredSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings)
    #expect(ignoredSemantics.emptyState == "No apps playing audio")
    #expect(ignoredSemantics.ignoredEmptyHint == "2 ignored · edit to manage")
    _ = try fixture.checkVisible(
      phase: "ignored-empty",
      markers: ["Quit", "No apps playing audio", "2 ignored", "edit to manage"])
    source.snapshot = cold
    fixture.layout()

    source.snapshot = warm
    fixture.layout()
    let warmHeight = try fixture.checkVisible(
      phase: "warm", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(warmHeight > coldHeight + 100)
    #expect(abs(warmHeight - warmOnFirstOpen) < 2)

    source.profileSource.snapshot.selection = AutoEQSelection(profileID: "studio", isEnabled: true)
    source.profileSource.snapshot.profileName = "Studio Profile"
    fixture.layout()
    let subtitleHeight = try fixture.checkVisible(
      phase: "subtitle", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(subtitleHeight >= warmHeight)
    #expect(source.profileSource.snapshot.selection != nil)
    #expect(
      MixerPopupSemantics(snapshot: source.snapshot, bindings: source.bindings)
        .apps.last?.name == "Player 4")

    source.snapshot = cold
    source.profileSource.snapshot.selection = nil
    source.profileSource.snapshot.profileName = nil
    fixture.layout()
    let shrunkHeight = try fixture.checkVisible(
      phase: "shrink", markers: ["Quit", "No apps playing audio"])
    #expect(abs(shrunkHeight - coldHeight) < 2)
    #expect(
      MixerPopupSemantics(snapshot: source.snapshot, bindings: source.bindings).emptyState
        == "No apps playing audio")

    fixture.popover.close()
    source.snapshot = warm
    fixture.layout()
    fixture.show()
    fixture.layout()
    let reopenedHeight = try fixture.checkVisible(
      phase: "reopen", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(abs(reopenedHeight - warmHeight) < 2)
    let reopenedSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings)
    #expect(reopenedSemantics.outputName == "First Output")
    #expect(reopenedSemantics.apps.last?.name == "Player 4")
    #expect(reopenedSemantics.sectionHeader == "APPS")
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test(
    "Maximum app volume keeps the device slider silhouette in the shown native popup",
    .timeLimit(.minutes(1)))
  @available(macOS 14.4, *)
  func maximumAppVolumeSliders() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot = warmPopupSnapshot(source)
    source.snapshot.apps = Array(source.snapshot.apps.prefix(2))
    for index in source.snapshot.apps.indices { source.snapshot.apps[index].gain = 1 }
    source.snapshot.outputDevices[0].volume = 1
    let fixture = try ShownPopupFixture(source: source)
    fixture.popover.animates = false
    defer { fixture.close() }
    fixture.show()
    let hosting = try fixture.hostingController()
    let window = try #require(hosting.view.window)
    let host = try #require(window.contentView)
    window.makeKey()
    try #require(window.makeFirstResponder(hosting.view))
    fixture.layout()
    // ScreenCaptureKit needs one display cycle to register the just-shown native popup window.
    try await Task.sleep(for: .milliseconds(120))
    fixture.layout()
    // This CLI test process cannot become the foreground application. Capture only this owned
    // popup through the current-process API; never enumerate foreign windows or capture a display.
    let fields = fixture.editableFieldFrames(in: host)
    try #require(fields.count == 4)
    #expect(source.snapshot.outputDevices[0].volume == 1)
    #expect(source.snapshot.apps.allSatisfy { $0.gain == 1 })
    let content = try await SCShareableContent.currentProcess
    let ownWindow = try #require(
      content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    try #require(
      ownWindow.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
    #expect(window.isVisible && ownWindow.isOnScreen)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width * 2)
    configuration.height = Int(window.frame.height * 2)
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.includeChildWindows = false
    configuration.scalesToFit = true
    let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("native-max-volume-sliders.png"))
    }
    let scaleX = CGFloat(image.width) / window.frame.width
    let scaleY = CGFloat(image.height) / window.frame.height
    for (index, field) in fields.enumerated() {
      let local = CGRect(x: field.minX - 8 - 140 - 4, y: field.midY - 14, width: 148, height: 28)
      let region = host.convert(local, to: nil)
      let top = window.frame.height - region.maxY
      var blueY: [Int] = []
      for y in Int(top * scaleY)..<Int((top + region.height) * scaleY) {
        for x in Int(region.minX * scaleX)..<Int(region.maxX * scaleX) {
          let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          if color.blueComponent > color.redComponent + 0.25
            && color.blueComponent > color.greenComponent + 0.1
          {
            blueY.append(y)
          }
        }
      }
      // The production 4pt accent fill is drawn without a public view value; this narrow height
      // probe only asserts the documented track silhouette.
      let minimum = try #require(blueY.min())
      let maximum = try #require(blueY.max())
      let height = CGFloat(maximum - minimum + 1) / scaleY
      #expect(
        height >= 3 && height <= 5, "Native slider \(index) blue silhouette height: \(height)")
    }
    #expect(source.events.isEmpty)
  }

  @Test(
    "An app output picker opens inside the transient popup and routes without closing its parent")
  func nativeAppRoutePicker() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot = warmPopupSnapshot(source)
    let routedApp = try #require(
      source.snapshot.apps.first { $0.id == "com.example.player-4" })
    // The child popover's window is not part of the test window's active key-view loop, so SwiftUI
    // installs no per-button focus/key-view proxies under its content view. Measure the same
    // production menu in an active offscreen host, where those native row proxies exist, and keep
    // the Second Output row center in the menu scroll view's coordinate space.
    let secondOutputOffset = try routeMenuSecondOutputOffset(
      app: routedApp, bindings: source.bindings)
    let fixture = try ShownPopupFixture(source: source)
    fixture.popover.behavior = .transient
    defer { fixture.close() }
    fixture.show()
    fixture.layout()
    let hosting = try fixture.hostingController()
    let host = hosting.view
    let parentWindow = try #require(host.window)
    parentWindow.makeKey()
    try #require(parentWindow.makeFirstResponder(host))
    let fields = fixture.editableFieldFrames(in: host)
    let percentage = try #require(fields.last)
    try fixture.sendClick(CGPoint(x: percentage.maxX + 44, y: percentage.midY), in: host)
    try await fixture.waitUntil("the app output picker's child popover to appear") {
      parentWindow.childWindows?.contains { $0.isVisible } == true
    }
    #expect(fixture.popover.isShown && parentWindow.isVisible)
    let child = try #require(parentWindow.childWindows?.first { $0.isVisible })
    let content = try #require(child.contentView)
    content.layoutSubtreeIfNeeded()
    child.displayIfNeeded()
    let renderedText = try recognizedText(
      in: bitmapImage(in: content), opaqueBackground: CGColor(gray: 1, alpha: 1))
    #expect(renderedText.contains { $0.text.contains("Single") })
    #expect(renderedText.contains { $0.text.contains("Multi") })
    #expect(renderedText.contains { $0.text.contains("System Audio") })
    let secondOutputText = try #require(renderedText.first { $0.text.contains("Second Output") })
    #expect(secondOutputText.bounds.width > 0 && secondOutputText.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(secondOutputText.bounds))
    #expect(source.events.isEmpty)
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      try writePNG(
        of: content,
        to: URL(fileURLWithPath: directory).appendingPathComponent("native-app-route-picker.png"))
    }
    // Map the production-measured Second Output row through the child popover's own scroll
    // document. This uses the actual child-content hierarchy and its hit target instead of a
    // screenshot, glyph probe or a coordinate recomputed from fixture dimensions.
    let childScroll = try #require(
      descendants(of: content).compactMap { $0 as? NSScrollView }.first,
      "The child popover hosts the production route menu's scroll container")
    let childDocument = try #require(
      childScroll.documentView, "The route menu scrolls its rendered option rows")
    #expect(childDocument.bounds.width > 0 && childDocument.bounds.height > 0)
    let secondOutput = childDocument.convert(secondOutputOffset, to: content)
    #expect(content.bounds.contains(secondOutput))
    try fixture.sendClick(secondOutput, in: content)
    try await fixture.waitUntil("the app route selection to dismiss the child popover") {
      source.events == ["route"] && !child.isVisible
    }
    #expect(source.events == ["route"])
    #expect(source.lastAppID == "com.example.player-4")
    #expect(source.lastMode == .single && source.lastUIDs == ["second-output"])
    // The command is observed; the menu must not optimistically rewrite the app's route.
    let observed = try #require(
      source.snapshot.apps.first { $0.id == "com.example.player-4" })
    #expect(observed.isFollowingDefault && observed.selectionMode == .single)
    #expect(observed.selectedDeviceUIDs.isEmpty)
    #expect(!child.isVisible)
    #expect(parentWindow.isVisible && fixture.popover.isShown)
    _ = try fixture.checkVisible(
      phase: "after-app-route-picker", markers: ["Quit", "Player 4", "APPS"])
  }

  @Test(
    "Keyboard selection surrounds the device controls with equal horizontal breathing room",
    arguments: MenuBarPopupSize.allCases)
  func deviceSelectionHorizontalInsets(size: MenuBarPopupSize) async throws {
    let source = MixerTestSource()
    source.snapshot.settings.popupSize = size
    source.snapshot.settings.appearance = .light
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    let hosting = try fixture.hostingController()
    let host = hosting.view
    let window = try #require(host.window)
    window.makeKey()
    try #require(window.makeFirstResponder(host))
    fixture.layout()
    let beforeFrame = try #require(fixture.editableFieldFrames(in: host).first)
    let before = NSBitmapImageRep(cgImage: try bitmapImage(in: host))
    try fixture.sendKey("\u{f701}", keyCode: 125)
    fixture.layout()
    let afterFrame = try #require(fixture.editableFieldFrames(in: host).first)
    let after = NSBitmapImageRep(cgImage: try bitmapImage(in: host))
    #expect(beforeFrame == afterFrame, "Highlighting must not move the device controls.")
    let padding = size.dimensions.contentPadding
    let outset = DesignTokens.Spacing.sm
    func pixelChange(at x: CGFloat) throws -> CGFloat {
      let pixelX = Int(x * CGFloat(after.pixelsWide) / host.bounds.width)
      let top = host.isFlipped ? afterFrame.midY : host.bounds.height - afterFrame.midY
      let pixelY = Int(top * CGFloat(after.pixelsHigh) / host.bounds.height)
      let old = try #require(before.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB))
      let new = try #require(after.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB))
      return abs(new.redComponent - old.redComponent)
        + abs(new.greenComponent - old.greenComponent)
        + abs(new.blueComponent - old.blueComponent)
        + abs(new.alphaComponent - old.alphaComponent)
    }
    // Drawn-only selection highlight: probe the empty margins, not the badge, text or controls.
    for x in [padding - outset / 2, host.bounds.width - padding + outset / 2] {
      #expect(try pixelChange(at: x) > 0.05, "Selection must extend beyond both content edges.")
    }
    for x in [padding - outset - 2, host.bounds.width - padding + outset + 2] {
      #expect(try pixelChange(at: x) < 0.01, "Selection must retain the outer popup margins.")
    }
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      try writePNG(
        of: host,
        to: URL(fileURLWithPath: directory).appendingPathComponent("device-selection-\(size).png"))
    }
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test("Expanding EQ through the shown popup's own key events naturally resizes its actual window")
  func naturalExpandedEqualizer() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot = warmPopupSnapshot(source)
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    fixture.layout()
    let initialHeight = try fixture.checkVisible(
      phase: "before-eq", markers: ["Quit", "First Output", "Player 4", "APPS"])
    let hosting = try fixture.hostingController()
    let popupWindow = try #require(hosting.view.window)
    popupWindow.makeKey()
    #expect(popupWindow.makeFirstResponder(hosting.view))
    // Wake on device one, move past device two to app one, then expand its EQ. No global posting.
    for _ in 0..<3 { try fixture.sendKey("\u{f701}", keyCode: 125) }
    try fixture.sendKey("\r", keyCode: 36)
    fixture.layout()
    let expandedHeight = try fixture.checkVisible(
      phase: "expanded-eq", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(expandedHeight > initialHeight + 100)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }
}

@MainActor
private func warmPopupSnapshot(_ source: MixerTestSource) -> MixerSnapshot {
  var snapshot = source.snapshot
  let original = snapshot.outputDevices[0].device
  snapshot.outputDevices[0].device = AudioDevice(
    id: original.id, uid: original.uid, name: "First Output", icon: nil, supportsAutoEQ: true)
  var second = snapshot.outputDevices[0]
  second.device = AudioDevice(
    id: 202, uid: "second-output", name: "Second Output", icon: nil, supportsAutoEQ: true)
  second.isDefault = false
  snapshot.outputDevices.append(second)
  // Four compact rows still exercise substantial native growth beyond the taller original empty state.
  snapshot.apps = popupApps(count: 4)
  return snapshot
}

/// Returns the Second Output row's center in the production route menu's scroll-document coordinate
/// space. The menu is the same `MixerAppRouteMenu` the child popover renders; this host is the
/// active context where SwiftUI exposes its real key-view proxies, so the returned point comes from
/// a rendered control rather than a layout formula or a pixel probe. The caller maps the point
/// through the child popover's actual scroll document.
///
/// Mode and option controls are located separately because only the option rows live in the
/// production `ScrollView`: the mode buttons render outside its document. Framework focus-ring
/// decorations are not part of a control's keyboard-loop identity, so they are excluded from the
/// per-control counts instead of being grouped into button rows.
@MainActor
private func routeMenuSecondOutputOffset(
  app: MixerAppPresentation, bindings: MixerBindings
) throws -> CGPoint {
  _ = NSApplication.shared
  let host = NSHostingView(
    rootView: AnyView(
      MixerAppRouteMenu(app: app, bindings: bindings, dismiss: {})
        .frame(width: 210)
        .focusable()
        .environment(\.controlActiveState, .active)
        .environment(\.colorScheme, .light)))
  host.appearance = NSAppearance(named: .aqua)
  let window = NSWindow(
    contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
    styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.appearance = host.appearance
  window.contentView = host
  defer {
    window.orderOut(nil)
    window.close()
  }
  window.orderFrontRegardless()
  host.setFrameSize(host.fittingSize)
  window.setContentSize(host.frame.size)
  host.layoutSubtreeIfNeeded()
  host.setFrameSize(host.fittingSize)
  window.setContentSize(host.frame.size)
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()

  let scroll = try #require(
    descendants(of: host).compactMap { $0 as? NSScrollView }.first,
    "The production route menu scrolls its option rows")
  let document = try #require(
    scroll.documentView, "The route menu renders its option rows into the scroll document")
  let scrollFrame = host.convert(scroll.bounds, from: scroll)
  let documentFrame = host.convert(document.bounds, from: document)
  let controls = routeMenuControlFrames(in: host)
  // Option rows are the rendered controls inside the menu's production scroll document; the two
  // mode buttons render above that document. Grouping each region separately keeps focus-ring
  // decoration from masquerading as an extra control row, while still requiring both mode controls
  // and all three option controls exactly once.
  let optionFrames = controls.filter { control in
    documentFrame.contains(CGPoint(x: control.midX, y: control.midY))
  }
  let modeFrames = controls.filter { control in
    host.isFlipped
      ? control.maxY <= scrollFrame.minY + 0.5
      : control.minY >= scrollFrame.maxY - 0.5
  }
  #expect(
    controls.count == modeFrames.count + optionFrames.count,
    "Every rendered route-menu control is a mode or option control; controls=\(controls)")
  #expect(
    modeFrames.count == 2,
    "Single and Multi render as the two mode controls above the scroll document; modes=\(modeFrames)"
  )
  let modeRows = renderedControlRows(modeFrames, isFlipped: host.isFlipped)
  #expect(modeRows.count == 1, "Single and Multi share the first rendered row; rows=\(modeRows)")
  #expect(
    optionFrames.count == 3,
    "System Audio, First Output and Second Output each render an option control; options=\(optionFrames)"
  )
  let optionRows = renderedControlRows(optionFrames, isFlipped: host.isFlipped)
  #expect(optionRows.count == 3, "The three option rows render separately; rows=\(optionRows)")
  #expect(
    optionRows.allSatisfy { $0.count == 1 },
    "Each rendered option row has its own control; rows=\(optionRows)")
  let secondOutput = try #require(optionRows.last?.first, "The last option row is Second Output")
  let offset = document.convert(CGPoint(x: secondOutput.midX, y: secondOutput.midY), from: host)
  #expect(document.bounds.contains(offset))
  return offset
}

/// Route-menu rows use only the keyboard-loop identity for each control. Focus-ring proxies draw
/// around those controls and are not a one-to-one control identity, so they are excluded here.
@MainActor
private func routeMenuControlFrames(in host: NSView) -> [CGRect] {
  nativeButtonProxyFrames(in: host, includeFocusRingProxies: false)
}

/// A framework-owned popover transition that did not complete within the fixture's fixed bound.
private struct PopupTransitionTimeout: Error, CustomStringConvertible {
  let transition: String
  let timeout: Duration

  var description: String { "Timed out after \(timeout) waiting for \(transition)" }
}

/// The controller remains owned by NSPopover. The independent window contains only an empty anchor.
@MainActor
private final class ShownPopupFixture {
  let popover: NSPopover
  let controller: NSViewController
  private let anchorWindow: NSWindow
  private let anchor: NSView

  init(source: MixerTestSource) throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main)
    popover = MenuBarPresentation.makePopover(content: popupView(source))
    controller = try #require(popover.contentViewController)
    popover.animates = false
    anchor = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
    anchorWindow = NSWindow(
      contentRect: NSRect(
        x: screen.visibleFrame.midX - 40, y: screen.visibleFrame.maxY - 80, width: 80, height: 24),
      styleMask: .titled, backing: .buffered, defer: false)
    anchorWindow.title = "Popup layout test"
    anchorWindow.isReleasedWhenClosed = false
    anchorWindow.contentView = anchor
  }

  func show() {
    anchorWindow.orderFrontRegardless()
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  func close() {
    popover.close()
    anchorWindow.orderOut(nil)
    anchorWindow.close()
  }

  /// Deterministic completion: the SwiftUI onGeometryChange callback publishes the new preferred
  /// size during this layout pass, so no fixed wall-clock wait is needed.
  func layout() {
    for _ in 0..<3 {
      controller.view.layoutSubtreeIfNeeded()
      controller.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
    controller.view.window?.displayIfNeeded()
  }

  /// Bounded state wait for framework-owned popover presentation/dismissal animations. A missed
  /// bound throws so a stalled transition fails the test instead of returning as if it completed.
  func waitUntil(
    _ transition: String, timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      guard clock.now < deadline else {
        throw PopupTransitionTimeout(transition: transition, timeout: timeout)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func hostingController() throws -> NSHostingController<AnyView> {
    try #require(controller.children.first as? NSHostingController<AnyView>)
  }

  func editableFields(in view: NSView) -> [NSTextField] {
    descendants(of: view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
  }

  func editableFieldFrames(in view: NSView) -> [CGRect] {
    editableFields(in: view)
      .map { view.convert($0.bounds, from: $0) }
      .sorted { view.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY }
  }

  func sendClick(_ point: CGPoint, in view: NSView) throws {
    let window = try #require(view.window)
    let location = view.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
  }

  func sendKey(_ characters: String, keyCode: UInt16) throws {
    let window = try #require(controller.view.window)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    window.sendEvent(event)
  }

  @discardableResult
  func checkVisible(phase: String, markers: [String]) throws -> CGFloat {
    #expect(popover.isShown)
    #expect(popover.contentViewController === controller)
    #expect(anchorWindow.contentView === anchor)
    let root = controller.view
    let hosting = try hostingController()
    let window = try #require(root.window)
    let viewport = try #require(window.contentView)
    #expect(window.isVisible)
    // Copy native geometry and its actually available viewport BEFORE any reference measurement.
    let rootBounds = root.bounds
    let hostBounds = hosting.view.bounds
    let hostInRoot = hosting.view.convert(hostBounds, to: root)
    let visible = rootBounds.intersection(root.visibleRect)
      .intersection(root.convert(viewport.bounds, from: viewport))
    let popupSize = popover.contentSize
    let preferred = controller.preferredContentSize
    let rootFrame = root.frame
    #expect(!descendants(of: root).contains { $0 is NSScrollView })
    #expect(!visible.isEmpty)
    #expect(visible.insetBy(dx: -1, dy: -1).contains(rootBounds))
    #expect(rootBounds.insetBy(dx: -1, dy: -1).contains(hostInRoot))
    #expect(abs(rootBounds.height - popupSize.height) < 2)

    // Render only this owned view's visible viewport; no desktop/window-server capture API.
    let image = try bitmapImage(in: root, rect: visible)
    // Native materials leave alpha holes in cacheDisplay. This fixture explicitly uses light content.
    let text = try recognizedText(in: image, opaqueBackground: CGColor(gray: 1, alpha: 1))
    for marker in markers {
      let fullViewportContainsMarker = text.contains {
        $0.text.localizedCaseInsensitiveContains(marker)
      }
      if marker.localizedCaseInsensitiveCompare("Quit") == .orderedSame
        && !fullViewportContainsMarker
      {
        // The 9pt inactive footer label is below Vision's i/l confidence in a full-popup scan on
        // some OS versions. Crop the actual native Quit button proxy and OCR those rendered pixels;
        // the expected string stays exact and the proxy supplies only the crop bounds.
        let buttons = nativeButtonProxyFrames(in: root, minimumWidth: 40).filter {
          $0.height <= 30 && $0.width <= 200
        }
        let footer = try #require(
          root.isFlipped
            ? buttons.max(by: { $0.midY < $1.midY })
            : buttons.min(by: { $0.midY < $1.midY }))
        let footerRegion = footer.insetBy(dx: -4, dy: -4).intersection(root.bounds)
        let footerImage = try bitmapImage(in: root, rect: footerRegion)
        let footerText = try recognizedText(
          in: footerImage, opaqueBackground: CGColor(gray: 1, alpha: 1))
        let quitGlyph = try #require(
          footerText.first { $0.text.contains("Quit") },
          "\(phase): missing visible Quit; full=\(text.map(\.text)), footer=\(footerText.map(\.text))"
        )
        #expect(quitGlyph.bounds.width > 0 && quitGlyph.bounds.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(quitGlyph.bounds))
      } else {
        #expect(
          fullViewportContainsMarker,
          "\(phase): missing visible \(marker); text=\(text.map(\.text))")
      }
    }
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      let destination = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let bitmap = NSBitmapImageRep(cgImage: image)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: destination.appendingPathComponent("native-\(phase).png"))
    }
    // Reference only: this query never writes a frame/preferred size or invokes our adapter callback.
    let ideal = hosting.sizeThatFits(
      in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    print(
      "Native popup \(phase): pop=\(popupSize), preferred=\(preferred), root=\(rootFrame)/\(rootBounds), host=\(hostInRoot), visible=\(visible), ideal=\(ideal)"
    )
    #expect(abs(hostBounds.height - ideal.height) < 2)
    #expect(abs(rootBounds.height - ideal.height) < 2)
    #expect(abs(popupSize.height - ideal.height) < 2)
    return ideal.height
  }
}

@MainActor
private final class PopupLayoutFixture {
  let popover: NSPopover
  var controller: NSViewController { popover.contentViewController! }
  let window: NSWindow
  var host: NSView { controller.view }

  init(source: MixerTestSource) {
    _ = NSApplication.shared
    popover = MenuBarPresentation.makePopover(content: popupView(source))
    let content = popover.contentViewController!
    let size = content.preferredContentSize
    window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    host.setFrameSize(size)
    host.layoutSubtreeIfNeeded()
  }

  isolated deinit { window.close() }

  func hostingController() throws -> NSHostingController<AnyView> {
    try #require(controller.children.first as? NSHostingController<AnyView>)
  }

  func showForPointerInput() throws {
    window.orderFrontRegardless()
    _ = window.makeFirstResponder(host)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  func editableFieldFrames(in view: NSView) -> [CGRect] {
    descendants(of: view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .map { view.convert($0.bounds, from: $0) }
      .sorted { view.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY }
  }

  func sendClick(_ point: CGPoint, in view: NSView) throws {
    let window = try #require(view.window)
    let location = view.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
    host.layoutSubtreeIfNeeded()
  }
}

@MainActor
private func popupView(_ source: MixerTestSource) -> MixerView {
  MixerView(
    read: { source.snapshot }, actions: source.actions, profiles: source.profileSource.interface,
    quit: { source.events.append("quit") })
}

private func popupApps(count: Int) -> [MixerAppPresentation] {
  (1...count).map { index in
    MixerAppPresentation(
      id: "com.example.player-\(index)", name: "Player \(index)", icon: nil,
      isActive: true, gain: 0.25, isMuted: false, boost: .x1, selectionMode: .single,
      isFollowingDefault: true, selectedDeviceUIDs: [], eqSettings: .flat,
      isPinned: false, isIgnored: false, routeStatus: nil)
  }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
private func writePNG(of view: NSView, to destination: URL) throws {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: bitmap)
  let png = try #require(bitmap.representation(using: .png, properties: [:]))
  try png.write(to: destination)
}

private struct RecognizedPopupText {
  let text: String
  let bounds: CGRect
}

private func recognizedText(in image: CGImage, opaqueBackground: CGColor? = nil) throws
  -> [RecognizedPopupText]
{
  // Native capture can be 1x. Resample the actual viewport at 3x for small labels and use standard
  // English language correction. No custom words or accepted misspellings are injected; exact
  // expected markers and their bounds remain unchanged.
  let scale = 3
  let context = try #require(
    CGContext(
      data: nil, width: image.width * scale, height: image.height * scale,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.interpolationQuality = .high
  let canvas = CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale)
  if let opaqueBackground {
    context.setFillColor(opaqueBackground)
    context.fill(canvas)
  }
  context.draw(image, in: canvas)
  let input = try #require(context.makeImage())
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["en-US"]
  request.usesLanguageCorrection = true
  request.minimumTextHeight = 0
  try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
  return (request.results ?? []).compactMap { observation in
    observation.topCandidates(1).first.map {
      RecognizedPopupText(text: $0.string, bounds: observation.boundingBox)
    }
  }
}

@MainActor
private func bitmapImage(in view: NSView, rect: NSRect? = nil) throws -> CGImage {
  let region = rect ?? view.bounds
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: region))
  view.cacheDisplay(in: region, to: bitmap)
  return try #require(bitmap.cgImage)
}
