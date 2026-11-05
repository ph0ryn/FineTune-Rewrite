// Production SwiftUI/AppKit components only, with explicit fake actions.
// Fitted-view unit fixtures stay offscreen. Native lifecycle fixtures briefly show only their own
// anchor window and popover, always clean up, and never start application services or permissions.
import AppKit
import FineTuneDomain
import FineTunePlatform
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

  @Test("Intrinsic height grows with all application rows instead of a fixed content viewport")
  func intrinsicHeightIncludesAllRows() {
    let source = MixerTestSource()
    source.snapshot.apps = []
    let empty = PopupLayoutFixture(source: source)
    let emptyHeight = empty.controller.preferredContentSize.height
    source.snapshot.apps = popupApps(count: 6)
    let populated = PopupLayoutFixture(source: source)
    #expect(populated.controller.preferredContentSize.height > emptyHeight + 300)
    #expect(source.events.isEmpty)
  }

  @Test("The final application and its route control are inside the fitted production view")
  func lastApplicationIsVisible() throws {
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 4)
    let fixture = PopupLayoutFixture(source: source)
    let image = try bitmapImage(in: fixture.host)
    let text = try recognizedText(in: image)
    // Positive control, last row and its lower route must be recognized in the same actual bitmap.
    #expect(text.contains { $0.text.contains("Player 1") })
    let last = try #require(text.first { $0.text.contains("Player 4") })
    // Representative bottom-row control. The same row's two-letter EQ label is inspected in
    // the opt-in actual bitmap; Vision did not reliably recognize it, even though it is visible.
    let route = try #require(
      text.first {
        $0.text.contains("System Default") && $0.bounds.maxY < last.bounds.minY
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
      let retry = try #require(text.first { $0.text.contains("Retry Audio") })
      #expect(retry.bounds.width > 0 && retry.bounds.height > 0)
      #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(retry.bounds))
      if action == .openSettings {
        let settings = try #require(text.first { $0.text.contains("Open System Settings") })
        #expect(settings.bounds.width > 0 && settings.bounds.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(settings.bounds))
      }
      #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
    }
  }

  @Test("Quit is a visible button in the header, not an item hidden below the application list")
  func quitIsVisible() throws {
    let source = MixerTestSource()
    source.snapshot.apps = popupApps(count: 4)
    let fixture = PopupLayoutFixture(source: source)
    let text = try recognizedText(in: bitmapImage(in: fixture.host))
    #expect(text.contains { $0.text.contains("Player 1") })
    let quit = try #require(text.first { $0.text.contains("Quit") })
    #expect(quit.bounds.width > 0 && quit.bounds.height > 0)
    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(quit.bounds))
    #expect(quit.bounds.midY > 0.8)
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
      markers: ["Quit", "First Output", "Player 2", "System Default"])
    source.snapshot = cold
    try await fixture.settle()
    let coldHeight = try fixture.checkVisible(
      phase: "cold", markers: ["Quit", "Apps playing audio appear here"])

    source.snapshot = warm
    try await fixture.settle()
    let warmHeight = try fixture.checkVisible(
      phase: "warm", markers: ["Quit", "First Output", "Player 2", "System Default"])
    #expect(warmHeight > coldHeight + 100)

    source.profileSource.snapshot.selection = AutoEQSelection(profileID: "studio", isEnabled: true)
    source.profileSource.snapshot.profileName = "Studio Profile"
    try await fixture.settle()
    // The 9pt caption can be misread as "Studio Proflle" by Vision. Its live-layout change is
    // checked geometrically and retained in the bitmap; do not use that glyph ambiguity as clipping.
    _ = try fixture.checkVisible(
      phase: "subtitle", markers: ["Quit", "First Output", "Player 2", "System Default"])

    source.snapshot = cold
    source.profileSource.snapshot.selection = nil
    source.profileSource.snapshot.profileName = nil
    try await fixture.settle()
    let shrunkHeight = try fixture.checkVisible(
      phase: "shrink", markers: ["Quit", "Apps playing audio appear here"])
    #expect(abs(shrunkHeight - coldHeight) < 2)

    fixture.popover.close()
    source.snapshot = warm
    try await fixture.settle()
    fixture.show()
    try await fixture.settle()
    let reopenedHeight = try fixture.checkVisible(
      phase: "reopen", markers: ["Quit", "First Output", "Player 2", "System Default"])
    #expect(abs(reopenedHeight - warmHeight) < 2)
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
    try await fixture.settle()
    let initialHeight = try fixture.checkVisible(
      phase: "before-eq", markers: ["Quit", "First Output", "Player 2", "System Default"])
    let hosting = try fixture.hostingController()
    let popupWindow = try #require(hosting.view.window)
    popupWindow.makeKey()
    #expect(popupWindow.makeFirstResponder(hosting.view))
    // Wake on device one, move past device two to app one, then expand its EQ. No global posting.
    for _ in 0..<3 { try fixture.sendKey("\u{f701}", keyCode: 125) }
    try fixture.sendKey("\r", keyCode: 36)
    try await fixture.settle()
    let expandedHeight = try fixture.checkVisible(
      phase: "expanded-eq", markers: ["Quit", "First Output", "Player 2", "System Default"])
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
  snapshot.apps = popupApps(count: 2)
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
    let text = try recognizedText(in: image)
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
private func recognizedText(in image: CGImage) throws -> [RecognizedPopupText] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["en-US"]
  request.usesLanguageCorrection = false
  request.minimumTextHeight = 0
  try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
  return (request.results ?? []).compactMap { observation in
    observation.topCandidates(1).first.map {
      RecognizedPopupText(text: $0.string, bounds: observation.boundingBox)
    }
  }
}
