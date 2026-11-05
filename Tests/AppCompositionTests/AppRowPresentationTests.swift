// Production app row only, rendered in owned offscreen windows with fake actions.
// Geometry comes from the pinned original's 28pt header, 8x6 padding and fixed control columns.
import AppKit
import FineTuneDomain
import SwiftUI
import Testing
import Vision

@testable import FineTune

@Suite("Original application row presentation", .serialized)
@MainActor
struct AppRowPresentationTests {
  @Test(
    "Active and inactive rows keep the original 40pt header and all trailing icon controls",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious], [false, true])
  func compactHeader(size: MenuBarPopupSize, active: Bool) throws {
    let fixture = AppRowFixture(size: size, active: active)
    try fixture.writeArtifact("app-\(size)-\(active ? "active" : "inactive")-Light")
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    let percentage = try fixture.percentageFrame()
    // The existing plain native editor extends 2pt beyond either side of its 40pt SwiftUI slot.
    #expect(abs(percentage.width - 44) <= 0.5)
    // EQ16 + gap8 + route28 + gap8 + boost16 + gap8 + slot40 + end padding8 + native inset2.
    #expect(abs(percentage.minX - (fixture.host.bounds.width - 134)) <= 0.5)
    #expect(fixture.host.bounds.contains(percentage))
    let text = try fixture.text()
    #expect(text.contains { $0.contains("Player") })
    #expect(!text.contains { $0.contains("Not playing") || $0.contains("System Default") })
    #expect(fixture.source.events.isEmpty)
  }

  @Test(
    "App icons activate only active apps; name, mute, slider, boost and EQ retain independent actions",
    arguments: [false, true])
  func independentPointerActions(active: Bool) async throws {
    let fixture = AppRowFixture(size: .comfortable, active: active)
    try await fixture.show()
    defer { fixture.window.orderOut(nil) }
    let percentage = try fixture.percentageFrame()
    let y = percentage.midY
    try await fixture.click(CGPoint(x: 38, y: y))
    #expect(fixture.source.events == (active ? ["activate"] : []))
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: 72, y: y))
    #expect(fixture.source.events.isEmpty)

    try await fixture.click(CGPoint(x: percentage.minX - 8 - 140 - 8 - 8, y: y))
    #expect(fixture.source.events == ["app-mute"])
    #expect(fixture.source.lastAppID == "com.example.player" && fixture.source.lastBool == true)
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: percentage.minX - 8 - 140 * 0.25, y: y))
    #expect(fixture.source.events == ["app-volume"])
    #expect(fixture.source.lastAppID == "com.example.player")
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: percentage.maxX + 16, y: y))
    #expect(fixture.source.events == ["app-boost"] && fixture.source.lastBoost == .x2)
    fixture.source.events.removeAll()

    try await fixture.click(CGPoint(x: fixture.host.bounds.width - 16, y: y))
    #expect(fixture.host.bounds.height > 140)
    #expect(fixture.source.events.isEmpty)
    try await fixture.click(CGPoint(x: fixture.host.bounds.width - 16, y: y))
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    #expect(fixture.source.events.isEmpty)
  }

  @Test("Inactive dark rows keep the shared slider interactive", arguments: [false, true])
  func darkRows(muted: Bool) async throws {
    let fixture = AppRowFixture(size: .comfortable, active: false, appearance: .dark)
    fixture.source.snapshot.apps[0].isMuted = muted
    fixture.refresh()
    try fixture.writeArtifact("app-inactive-\(muted ? "muted" : "audible")-Dark")
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    try await fixture.show()
    defer { fixture.window.orderOut(nil) }
    let percentage = try fixture.percentageFrame()
    try await fixture.click(CGPoint(x: percentage.minX - 8 - 140 * 0.3, y: percentage.midY))
    #expect(fixture.source.events == ["app-volume"])
    #expect(fixture.source.lastAppID == "com.example.player")
  }

  @Test(
    "The original route menu delegates single, multi and default choices without optimistic selection"
  )
  func routeMenuActions() async throws {
    let fixture = AppRowFixture(size: .comfortable, active: true, routeMenu: true)
    try await fixture.show()
    defer { fixture.window.orderOut(nil) }
    try fixture.writeArtifact("app-route-menu-single")
    try await fixture.click(CGPoint(x: 155, y: 18))
    #expect(fixture.source.events == ["route"])
    #expect(fixture.source.lastMode == .multi && fixture.source.lastUIDs == [])
    #expect(fixture.source.snapshot.apps[0].selectionMode == .single)
    fixture.source.events.removeAll()

    fixture.source.snapshot.apps[0].selectionMode = .multi
    fixture.source.snapshot.apps[0].isFollowingDefault = false
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = ["output-uid"]
    fixture.refresh()
    try fixture.writeArtifact("app-route-menu-multi")
    let outputY = fixture.host.bounds.height - 19
    try await fixture.click(CGPoint(x: 90, y: outputY - 28))
    #expect(fixture.source.events.isEmpty, "System Audio is unavailable in multi mode")
    try await fixture.click(CGPoint(x: 90, y: outputY))
    #expect(fixture.source.events == ["route"])
    #expect(fixture.source.lastMode == .multi && fixture.source.lastUIDs == [])
    fixture.source.events.removeAll()
    // The fake command did not change observations: another click must use the still-selected UID.
    try await fixture.click(CGPoint(x: 90, y: outputY))
    #expect(fixture.source.lastUIDs == [])
    #expect(fixture.source.events == ["route"])
    fixture.source.events.removeAll()

    fixture.source.snapshot.apps[0].selectionMode = .single
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = []
    fixture.refresh()
    try await fixture.click(CGPoint(x: 90, y: outputY))
    #expect(fixture.source.events == ["route", "dismiss"])
    #expect(fixture.source.lastMode == .single && fixture.source.lastUIDs == ["output-uid"])
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: 90, y: outputY - 28))
    #expect(fixture.source.events == ["follow-default", "dismiss"])
    #expect(fixture.source.lastAppID == "com.example.player")
  }

  @Test("Nondefault and unavailable route subtitles replace the permanent second control line")
  func routingSubtitle() throws {
    let fixture = AppRowFixture(size: .spacious, active: true, followingDefault: false)
    #expect(try fixture.text().contains { $0.contains("Output") })
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = ["missing-device"]
    fixture.refresh()
    #expect(try fixture.text().contains { $0.contains("Unavailable") })
    #expect(fixture.source.events.isEmpty)
  }
}

@MainActor
private final class AppRowFixture {
  let source = MixerTestSource()
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(
    size: MenuBarPopupSize, active: Bool, followingDefault: Bool = true,
    routeMenu: Bool = false, editing: Bool = false, appearance: AppearancePreference = .light
  ) {
    _ = NSApplication.shared
    source.snapshot.apps[0].isActive = active
    source.snapshot.apps[0].isFollowingDefault = followingDefault
    source.snapshot.apps[0].selectedDeviceUIDs = followingDefault ? [] : ["output-uid"]
    let source = source
    host = NSHostingView(
      rootView: AnyView(
        AppRowHarness(source: source, routeMenu: routeMenu, editing: editing)
          .frame(
            width: routeMenu ? 210 : size.dimensions.width - 2 * size.dimensions.contentPadding
          )
          .focusable()
          .accentColor(.blue)
          .environment(\.controlActiveState, .active)
          .environment(\.colorScheme, appearance == .dark ? .dark : .light)
          .background(Color(nsColor: .windowBackgroundColor))))
    host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    refresh()
  }

  isolated deinit { window.close() }

  func refresh() {
    host.setFrameSize(host.fittingSize)
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
  }

  func percentageFrame() throws -> CGRect {
    func fields(_ view: NSView) -> [NSTextField] {
      view.subviews.flatMap { child -> [NSTextField] in
        let own = (child as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + fields(child)
      }
    }
    let field = try #require(fields(host).first)
    return host.convert(field.bounds, from: field)
  }

  func bitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  func writeArtifact(_ name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["FINETUNE_APP_ROW_EVIDENCE"] else {
      return
    }
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let png = try #require(bitmap().representation(using: .png, properties: [:]))
    try png.write(to: destination.appendingPathComponent("\(name).png"))
  }

  func text() throws -> [String] {
    let image = try #require(bitmap().cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  }

  func show() async throws {
    window.initialFirstResponder = host
    window.orderFrontRegardless()
    try await settle()
    try #require(window.makeFirstResponder(host))
    // An unchanged native editor may commit when initial focus leaves it; prepare the pointer phase.
    #expect(source.events.allSatisfy { $0 == "app-volume" })
    source.events.removeAll()
  }

  func click(_ point: CGPoint) async throws {
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
    try await settle()
  }

  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(400))
    refresh()
    window.displayIfNeeded()
  }
}

@MainActor
private struct AppRowHarness: View {
  let source: MixerTestSource
  var routeMenu = false
  var editing = false
  @State private var expanded = false

  var body: some View {
    if routeMenu {
      MixerAppRouteMenu(
        app: source.snapshot.apps[0], bindings: source.bindings,
        dismiss: { source.events.append("dismiss") })
    } else {
      MixerAppRow(
        app: source.snapshot.apps[0], bindings: source.bindings, isEditing: editing,
        percentageDraft: nil, isEQExpanded: $expanded)
    }
  }
}
