// AppKit popover and hosting-controller structural contracts without Vision OCR,
// ScreenCaptureKit, private SwiftUI view proxies, or synthetic pointer coordinates.
import AppKit
import FineTuneDomain
import SwiftUI
import Testing

@testable import FineTune

@Suite("Non-scrolling production popup layout")
@MainActor
struct PopupLayoutTests {
  @Test("The actual mixer has no vertical scroll container")
  func noVerticalScrollContainer() throws {
    _ = NSApplication.shared
    let source = MixerTestSource()
    let popover = MenuBarPresentation.makePopover(content: popupView(source))
    let controller = try #require(popover.contentViewController)
    #expect(!leafDescendants(of: controller.view).contains { $0 is NSScrollView })
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }

  @Test("The own offscreen window's Quit key equivalent invokes only its required fake action")
  func quitKeyEquivalentUsesRequiredAction() throws {
    let source = MixerTestSource()
    let fixture = try PopoverHostFixture(source: source)
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: fixture.window.windowNumber, context: nil, characters: "q",
        charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
    let handled = fixture.window.performKeyEquivalent(with: event)
    #expect(handled)
    #expect(source.events == ["quit"])
  }

  @Test("The production factory assigns its initial fitted size before presentation")
  func initialPopoverSizeIsResolved() throws {
    _ = NSApplication.shared
    let source = MixerTestSource()
    source.snapshot.apps = []
    let popover = MenuBarPresentation.makePopover(content: popupView(source))
    let controller = try #require(popover.contentViewController)
    #expect(controller.preferredContentSize.height > 0)
    #expect(popover.contentSize == controller.preferredContentSize)
    #expect(controller.view.frame.size == controller.preferredContentSize)
    #expect(!popover.isShown && source.events.isEmpty)
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

  @Test("Popover content size follows cold, warm, shrink, and equalizer expansion transitions")
  func popoverResizesOnSnapshotAndEqualizerChanges() throws {
    let source = MixerTestSource()
    let warm = warmPopupSnapshot(source)
    var cold = warm
    cold.apps = []
    cold.outputDevices = []
    cold.inputDevices = []
    source.snapshot = cold

    let fixture = try PopoverHostFixture(source: source)
    let coldHeight = fixture.popover.contentSize.height
    #expect(coldHeight > 0)
    #expect(abs(fixture.controller.preferredContentSize.height - coldHeight) < 2)

    source.snapshot = warm
    fixture.layout()
    let warmHeight = fixture.popover.contentSize.height
    #expect(warmHeight > coldHeight + 100)
    #expect(abs(fixture.controller.preferredContentSize.height - warmHeight) < 2)
    #expect(abs(fixture.idealHeight() - warmHeight) < 2)

    source.snapshot = cold
    fixture.layout()
    let shrunkHeight = fixture.popover.contentSize.height
    #expect(abs(shrunkHeight - coldHeight) < 2)
    #expect(abs(fixture.idealHeight() - shrunkHeight) < 2)

    source.snapshot = warm
    let expandedPopover = MenuBarPresentation.makePopover(
      content: popupView(source, initialExpandedAppID: warm.apps[0].id))
    let expandedController = try #require(expandedPopover.contentViewController)
    let expandedHeight = expandedPopover.contentSize.height
    #expect(expandedHeight > warmHeight + 100)
    #expect(abs(expandedController.preferredContentSize.height - expandedHeight) < 2)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
  }
}

@MainActor
private final class PopoverHostFixture {
  let popover: NSPopover
  let controller: NSViewController
  let window: NSWindow

  init(source: MixerTestSource) throws {
    _ = NSApplication.shared
    popover = MenuBarPresentation.makePopover(content: popupView(source))
    controller = try #require(popover.contentViewController)
    let size = controller.preferredContentSize
    window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    controller.view.setFrameSize(size)
    layout()
  }

  isolated deinit { window.close() }

  func layout() {
    for _ in 0..<3 {
      controller.view.layoutSubtreeIfNeeded()
      window.contentView?.layoutSubtreeIfNeeded()
    }
    window.displayIfNeeded()
  }

  func idealHeight() -> CGFloat {
    guard let hosting = controller.children.first as? NSHostingController<AnyView> else { return 0 }
    return hosting.sizeThatFits(
      in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    ).height
  }
}

@MainActor
private func popupView(_ source: MixerTestSource, initialExpandedAppID: String? = nil) -> MixerView
{
  MixerView(
    read: { source.snapshot }, actions: source.actions, profiles: source.profileSource.interface,
    quit: { source.events.append("quit") },
    initialExpandedAppID: initialExpandedAppID)
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
  snapshot.apps = (1...4).map { index in
    MixerAppPresentation(
      id: "com.example.player-\(index)", name: "Player \(index)", icon: nil,
      isActive: true, gain: 0.25, isMuted: false, boost: .x1, selectionMode: .single,
      isFollowingDefault: true, selectedDeviceUIDs: [], eqSettings: .flat,
      isPinned: false, isIgnored: false, routeStatus: nil)
  }
  return snapshot
}
