// Production SwiftUI/AppKit components only, with explicit fake actions.
// Fitted-view unit fixtures stay offscreen. Native lifecycle fixtures briefly show only their own
// anchor window and popover, always clean up, and never start application services or permissions.
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
    let image = try bitmapImage(in: fixture.host)
    let text = try recognizedText(in: image)
    // Positive control, last row and its nondefault routing subtitle share the same actual bitmap.
    #expect(text.contains { $0.text.contains("Player 1") })
    let last = try #require(text.first { $0.text.contains("Player 4") })
    // The original uses icon-only controls; their actions are covered by AppRowPresentationTests.
    // Here the actual nondefault subtitle proves the last row's lower text fits, not a hidden menu.
    let route = try #require(
      text.first {
        $0.text.contains("Output") && $0.bounds.maxY < last.bounds.minY
          && $0.bounds.minY > 0
      })
    for item in [last, route] {
      #expect(item.bounds.width > 0 && item.bounds.height > 0)
      #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(item.bounds))
    }
    #expect(source.events.isEmpty)
  }

  @Test("Capture recovery controls remain visible and rendering does not invoke them")
  func captureRecoveryIsExplicit() throws {
    for action in [MixerCaptureNotice.Action.retryCapture, .openSettings] {
      let source = MixerTestSource()
      source.snapshot.captureNotice = MixerCaptureNotice(
        message: "Capture needs an explicit retry.", action: action)
      let fixture = PopupLayoutFixture(source: source)
      let text = try recognizedText(in: bitmapImage(in: fixture.host))
      // Retry lives in the header as an accessible icon, not a duplicated inline text button.
      #expect(!text.contains { $0.text.contains("Retry Audio") })
      if action == .openSettings {
        let settings = try #require(text.first { $0.text.contains("Open System Settings") })
        #expect(settings.bounds.width > 0 && settings.bounds.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(settings.bounds))
      }
      #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
    }
  }

  @Test("Quit and its shortcut stay visible in the original footer below all application rows")
  func quitIsVisible() throws {
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 4)
    let fixture = PopupLayoutFixture(source: source)
    let text = try recognizedText(in: bitmapImage(in: fixture.host))
    #expect(text.contains { $0.text.contains("Player 1") })
    let quit = try #require(text.first { $0.text.contains("Quit") })
    #expect(quit.bounds.width > 0 && quit.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(quit.bounds))
    let last = try #require(text.first { $0.text.contains("Player 4") })
    #expect(quit.bounds.maxY < last.bounds.minY)
    #expect(quit.bounds.midY < 0.15)
    #expect(source.events.isEmpty)
  }

  @Test("The own offscreen window's Quit key equivalent invokes only its required fake action")
  func quitKeyEquivalentUsesRequiredAction() async throws {
    let source = MixerTestSource()
    let fixture = PopupLayoutFixture(source: source)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: fixture.window.windowNumber, context: nil, characters: "q",
        charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
    let handled = fixture.window.performKeyEquivalent(with: event)
    await Task.yield()
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
      if #available(macOS 27, *) { #expect(!glass.effectIsInteractive) }
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
  @Test("Current app warnings stay visible and update while reordering devices")
  func editingKeepsCurrentWarningsVisible() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot.apps[0].isActive = true
    source.snapshot.captureNotice = nil
    source.snapshot.error = "Unable to save settings."
    source.snapshot.apps[0].routeStatus = "Current audio route failed"
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    try await fixture.settle()
    let host = fixture.controller.view
    func text() throws -> String {
      try recognizedText(in: bitmapImage(in: host)).map(\.text).joined(separator: "\n")
    }
    let normal = try text()
    #expect(normal.contains("Current audio route"))
    let padding = source.snapshot.settings.popupSize.dimensions.contentPadding
    let target = DesignTokens.Dimensions.minTouchTarget
    let top = padding + target / 2
    try fixture.sendClick(
      CGPoint(
        x: host.bounds.maxX - padding - target / 2 - 2 * (target + DesignTokens.Spacing.sm),
        y: host.isFlipped ? top : host.bounds.maxY - top), in: host)
    try await fixture.settle()
    #expect(try text().contains("Current audio route"))
    #expect(try text().contains("Unable to save settings"))
    source.snapshot.apps[0].routeStatus = "Current audio cleanup failed"
    try await fixture.settle()
    #expect(try text().contains("Current audio cleanup"))
    #expect(try !text().contains("Current audio route"))
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
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    try await fixture.settle()
    let host = fixture.controller.view
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
    // Reordering must not hide or repurpose the neighboring recovery control.
    try fixture.sendClick(CGPoint(x: retryPoint.x - step, y: retryPoint.y), in: host)
    try await fixture.settle()
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
    try await fixture.settle()
    fixture.show()
    try await fixture.settle()
    _ = try fixture.checkVisible(
      phase: "hidden-warm-first-open",
      markers: ["Quit", "First Output", "Player 4", "APPS"])
    source.snapshot = cold
    try await fixture.settle()
    let coldHeight = try fixture.checkVisible(
      phase: "cold", markers: ["Quit", "No apps playing audio"])

    source.snapshot = warm
    try await fixture.settle()
    let warmHeight = try fixture.checkVisible(
      phase: "warm", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(warmHeight > coldHeight + 100)

    source.profileSource.snapshot.selection = AutoEQSelection(profileID: "studio", isEnabled: true)
    source.profileSource.snapshot.profileName = "Studio Profile"
    try await fixture.settle()
    // The 9pt caption can be misread as "Studio Proflle" by Vision. Its live-layout change is
    // checked geometrically and retained in the bitmap; do not use that glyph ambiguity as clipping.
    _ = try fixture.checkVisible(
      phase: "subtitle", markers: ["Quit", "First Output", "Player 4", "APPS"])

    source.snapshot = cold
    source.profileSource.snapshot.selection = nil
    source.profileSource.snapshot.profileName = nil
    try await fixture.settle()
    let shrunkHeight = try fixture.checkVisible(
      phase: "shrink", markers: ["Quit", "No apps playing audio"])
    #expect(abs(shrunkHeight - coldHeight) < 2)

    fixture.popover.close()
    source.snapshot = warm
    try await fixture.settle()
    fixture.show()
    try await fixture.settle()
    let reopenedHeight = try fixture.checkVisible(
      phase: "reopen", markers: ["Quit", "First Output", "Player 4", "APPS"])
    #expect(abs(reopenedHeight - warmHeight) < 2)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test("Maximum app volume keeps the device slider silhouette in the shown native popup")
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
    try await fixture.settle()
    // This CLI test process cannot become the foreground application. This checks maximum-value
    // rendering in its shown window; foreground-only focus effects require installed-app acceptance.
    // cacheDisplay omits native window-level focus effects. Capture this owned popup only,
    // using the current-process API which exposes content capturable without TCC consent.
    // Never enumerate other processes, request screen access, capture a display, or capture audio.
    let content = try await SCShareableContent.currentProcess
    let ownWindow = try #require(
      content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
    try #require(
      ownWindow.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
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
      contentFilter: filter,
      configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("native-max-volume-sliders.png"))
    }
    let scaleX = CGFloat(image.width) / window.frame.width
    let scaleY = CGFloat(image.height) / window.frame.height
    let fields = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .map { host.convert($0.bounds, from: $0) }
      .sorted { host.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY }
    try #require(fields.count == 4)
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
    let fixture = try ShownPopupFixture(source: source)
    fixture.popover.behavior = .transient
    defer { fixture.close() }
    fixture.show()
    try await fixture.settle()
    let hosting = try fixture.hostingController()
    let host = hosting.view
    let parentWindow = try #require(host.window)
    parentWindow.makeKey()
    try #require(parentWindow.makeFirstResponder(host))
    let fields = descendants(of: host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .map { host.convert($0.bounds, from: $0) }
      .sorted { host.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY }
    let percentage = try #require(fields.last)
    try fixture.sendClick(CGPoint(x: percentage.maxX + 44, y: percentage.midY), in: host)
    // Allow the framework-owned child popover's presentation/dismissal animation to complete.
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.popover.isShown && parentWindow.isVisible)
    let child = try #require(parentWindow.childWindows?.first { $0.isVisible })
    let content = try #require(child.contentView)
    content.layoutSubtreeIfNeeded()
    child.displayIfNeeded()
    if let directory = ProcessInfo.processInfo.environment["FINETUNE_POPUP_LAYOUT_EVIDENCE"] {
      try writePNG(
        of: content,
        to: URL(fileURLWithPath: directory).appendingPathComponent("native-app-route-picker.png"))
    }
    let text = try recognizedText(
      in: bitmapImage(in: content), opaqueBackground: CGColor(gray: 1, alpha: 1))
    print(
      "Native app route picker: window=\(child.frame), content=\(content.bounds), text=\(text.map(\.text))"
    )
    #expect(text.contains { $0.text.contains("Single") })
    #expect(text.contains { $0.text.contains("Multi") })
    #expect(text.contains { $0.text.contains("System Audio") })
    let output = try #require(text.first { $0.text.contains("Second Output") })
    #expect(source.events.isEmpty)
    let point = CGPoint(
      x: output.bounds.midX * content.bounds.width,
      y: (content.isFlipped ? 1 - output.bounds.midY : output.bounds.midY) * content.bounds.height)
    try fixture.sendClick(point, in: content)
    try await Task.sleep(for: .milliseconds(300))
    #expect(source.events == ["route"])
    #expect(source.lastAppID == "com.example.player-4")
    #expect(source.lastMode == .single && source.lastUIDs == ["second-output"])
    #expect(!child.isVisible)
    _ = try fixture.checkVisible(
      phase: "after-app-route-picker", markers: ["Quit", "Player 4", "APPS"])
  }

  @Test("Expanding EQ through the shown popup's own key events naturally resizes its actual window")
  func naturalExpandedEqualizer() async throws {
    let source = MixerTestSource()
    source.snapshot.settings.appearance = .light
    source.snapshot = warmPopupSnapshot(source)
    let fixture = try ShownPopupFixture(source: source)
    defer { fixture.close() }
    fixture.show()
    try await fixture.settle()
    let initialHeight = try fixture.checkVisible(
      phase: "before-eq", markers: ["Quit", "First Output", "Player 4", "APPS"])
    let hosting = try fixture.hostingController()
    let popupWindow = try #require(hosting.view.window)
    popupWindow.makeKey()
    #expect(popupWindow.makeFirstResponder(hosting.view))
    // Wake on device one, move past device two to app one, then expand its EQ. No global posting.
    for _ in 0..<3 { try fixture.sendKey("\u{f701}", keyCode: 125) }
    try fixture.sendKey("\r", keyCode: 36)
    try await fixture.settle()
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

  func settle() async throws {
    // One bounded display-cycle wait per input transition, not a product timer or polling loop.
    try await Task.sleep(for: .milliseconds(120))
    controller.view.window?.displayIfNeeded()
  }

  func hostingController() throws -> NSHostingController<AnyView> {
    try #require(controller.children.first as? NSHostingController<AnyView>)
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
      #expect(
        text.contains { $0.text.localizedCaseInsensitiveContains(marker) },
        "\(phase): missing visible \(marker); text=\(text.map(\.text))")
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

@MainActor
private func bitmapImage(in view: NSView, rect: NSRect? = nil) throws -> CGImage {
  let region = rect ?? view.bounds
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: region))
  view.cacheDisplay(in: region, to: bitmap)
  return try #require(bitmap.cgImage)
}

@MainActor
private func recognizedText(in image: CGImage, opaqueBackground: CGColor? = nil) throws
  -> [RecognizedPopupText]
{
  // Native capture can be 1x. Resample the actual viewport for small labels and use standard
  // English language correction for measured i/l raster ambiguity in Quit. No custom words or
  // accepted misspellings are injected; exact expected markers and their bounds stay unchanged.
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
