// Production SwiftUI/AppKit components only, with explicit fake actions.
// Offscreen windows are never ordered in; no application services or permissions are started.
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

  @Test("The production factory forwards actual child ideal-size notifications to its NSPopover")
  func popoverFollowsDynamicContent() async throws {
    let source = MixerTestSource()
    source.snapshot.apps = []
    let fixture = PopupLayoutFixture(source: source)
    let controller = fixture.controller
    let hosting = try #require(controller.children.first as? NSHostingController<MixerView>)
    let initialHeight = fixture.popover.contentSize.height
    #expect(initialHeight > 0)
    source.snapshot.apps = popupApps(count: 6)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    // A hidden host can defer automatic SwiftUI layout. Measure the actual changed content and
    // publish its size through AppKit's public child-controller notification contract, not a mock.
    let ideal = hosting.sizeThatFits(
      in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    hosting.preferredContentSize = ideal
    #expect(hosting.preferredContentSize == ideal)
    // Exercise our adapter, not AppKit's delivery to a never-shown child hierarchy.
    controller.preferredContentSizeDidChange(for: hosting)
    print(
      "Child ideal-size notification: initial=\(initialHeight), actual=\(ideal), popover=\(fixture.popover.contentSize)"
    )
    #expect(ideal.height > initialHeight + 300)
    #expect(fixture.popover.contentSize == ideal)
    #expect(controller.preferredContentSize == ideal)
    #expect(!fixture.popover.isShown && !fixture.window.isVisible && source.events.isEmpty)
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
      #expect(content is NSHostingView<MixerView>)
      #expect(!content.isOpaque)
      #expect(glass.style == .regular)
      #expect(glass.tintColor == nil)
      #expect(controller.preferredContentSize.height > 0)
    } else {
      #expect(controller.view is NSHostingView<MixerView>)
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
private func bitmapImage(in view: NSView) throws -> CGImage {
  let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: bitmap)
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
