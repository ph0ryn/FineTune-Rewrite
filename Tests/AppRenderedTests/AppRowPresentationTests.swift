// Production app row only, rendered in owned offscreen windows with fake actions.
// Geometry comes from the pinned original's 28pt header, 8x6 padding and fixed control columns.
// The host has no NSAccessibility text tree; row text visibility is checked by OCR on its actual
// bitmap, with semantic projection assertions as a separate copy oracle. Control frames and actions
// come from the rendered host. No desktop/window-server capture participates.
import AppKit
import FineTuneDomain
import Observation
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
    // The row renders this same presentation for its name and optional second line.
    let text = try fixture.text()
    #expect(text.contains { $0.contains("Player") })
    #expect(!text.contains { $0.contains("Not playing") || $0.contains("System Default") })
    #expect(fixture.presentation.name == "Player")
    #expect(fixture.presentation.subtitle == nil)
    #expect(fixture.source.snapshot.apps[0].routeStatus == nil)
    #expect(fixture.source.events.isEmpty)
  }

  @Test(
    "App icons activate only active apps; name, mute, slider, boost and EQ retain independent actions",
    arguments: [false, true])
  func independentPointerActions(active: Bool) async throws {
    let fixture = AppRowFixture(size: .comfortable, active: active)
    try fixture.show()
    defer { fixture.window.orderOut(nil) }
    let percentage = try fixture.percentageFrame()
    let y = percentage.midY
    try fixture.click(CGPoint(x: 38, y: y))
    #expect(fixture.source.events == (active ? ["activate"] : []))
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: 72, y: y))
    #expect(fixture.source.events.isEmpty)

    try fixture.click(CGPoint(x: percentage.minX - 8 - 140 - 8 - 8, y: y))
    #expect(fixture.source.events == ["app-mute"])
    #expect(fixture.source.lastAppID == "com.example.player" && fixture.source.lastBool == true)
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: percentage.minX - 8 - 140 * 0.25, y: y))
    #expect(fixture.source.events == ["app-volume"])
    #expect(fixture.source.lastAppID == "com.example.player")
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: percentage.maxX + 16, y: y))
    #expect(fixture.source.events == ["app-boost"] && fixture.source.lastBoost == .x2)
    fixture.source.events.removeAll()

    // The EQ button owns the row's expansion binding and its actual rendered frame; expansion
    // changes the fitted row height, not just a local flag. The button stays in the fixed 28pt
    // header, whose row-local position does not move when the panel grows the host below it, so
    // the fixture resolves that rendered proxy while the header is stable and reuses it for the
    // closing click.
    let collapsedHeight = fixture.host.bounds.height
    try fixture.click(try fixture.equalizerTarget(), settleForLayout: true)
    #expect(fixture.isEQExpanded)
    let expandedHeight = fixture.host.bounds.height
    #expect(expandedHeight > collapsedHeight + 100, "Expanded EQ adds its panel to the row")
    #expect(fixture.source.events.isEmpty)
    try fixture.click(try fixture.equalizerTarget(), settleForLayout: true)
    #expect(!fixture.isEQExpanded)
    #expect(abs(fixture.host.bounds.height - collapsedHeight) <= 0.5)
    #expect(fixture.source.events.isEmpty)
  }

  @Test("Inactive dark rows keep the shared slider interactive", arguments: [false, true])
  func darkRows(muted: Bool) async throws {
    let fixture = AppRowFixture(size: .comfortable, active: false, appearance: .dark)
    fixture.source.snapshot.apps[0].isMuted = muted
    fixture.refresh()
    try fixture.writeArtifact("app-inactive-\(muted ? "muted" : "audible")-Dark")
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    try fixture.show()
    defer { fixture.window.orderOut(nil) }
    let percentage = try fixture.percentageFrame()
    try fixture.click(CGPoint(x: percentage.minX - 8 - 140 * 0.3, y: percentage.midY))
    #expect(fixture.source.events == ["app-volume"])
    #expect(fixture.source.lastAppID == "com.example.player")
  }

  @Test(
    "The original route menu delegates single, multi and default choices without optimistic selection"
  )
  func routeMenuActions() async throws {
    let fixture = AppRowFixture(size: .comfortable, active: true, routeMenu: true)
    try fixture.show()
    defer { fixture.window.orderOut(nil) }
    #expect(fixture.host.bounds.height > 0)
    // The exact route copy and its mode/details mapping are asserted in
    // AppPresentationContractTests; the rendered menu below keeps the same labels as clickable
    // native mode and option controls.
    try fixture.writeArtifact("app-route-menu-single")
    var targets = try routeMenuTargets(in: fixture.host)
    #expect(targets.single.x < targets.multi.x, "Single is the left mode button")
    try fixture.click(targets.single)
    #expect(fixture.source.events.isEmpty, "The already observed single mode changes nothing")
    try fixture.click(targets.multi)
    #expect(fixture.source.events == ["route"])
    #expect(fixture.source.lastMode == .multi && fixture.source.lastUIDs == [])
    #expect(fixture.source.snapshot.apps[0].selectionMode == .single)
    fixture.source.events.removeAll()

    fixture.source.snapshot.apps[0].selectionMode = .multi
    fixture.source.snapshot.apps[0].isFollowingDefault = false
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = ["output-uid"]
    fixture.refresh()
    try fixture.writeArtifact("app-route-menu-multi")
    targets = try routeMenuTargets(in: fixture.host)
    try fixture.click(targets.systemAudio)
    #expect(fixture.source.events.isEmpty, "System Audio is unavailable in multi mode")
    try fixture.click(targets.output)
    #expect(fixture.source.events == ["route"])
    #expect(fixture.source.lastMode == .multi && fixture.source.lastUIDs == [])
    fixture.source.events.removeAll()
    // The fake command did not change observations: another click must use the still-selected UID.
    try fixture.click(targets.output)
    #expect(fixture.source.lastUIDs == [])
    #expect(fixture.source.events == ["route"])
    fixture.source.events.removeAll()

    fixture.source.snapshot.apps[0].selectionMode = .single
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = []
    fixture.refresh()
    targets = try routeMenuTargets(in: fixture.host)
    try fixture.click(targets.output)
    #expect(fixture.source.events == ["route", "dismiss"])
    #expect(fixture.source.lastMode == .single && fixture.source.lastUIDs == ["output-uid"])
    fixture.source.events.removeAll()
    try fixture.click(targets.systemAudio)
    #expect(fixture.source.events == ["follow-default", "dismiss"])
    #expect(fixture.source.lastAppID == "com.example.player")
  }

  @Test("Nondefault and unavailable route subtitles replace the permanent second control line")
  func routingSubtitle() throws {
    let fixture = AppRowFixture(size: .spacious, active: true, followingDefault: false)
    // The row body renders exactly this presentation under the app name.
    #expect(try fixture.text().contains { $0.contains("Output") })
    let subtitle = try #require(fixture.presentation.subtitle)
    #expect(subtitle == "Output")
    #expect(abs(fixture.host.bounds.height - 40) <= 0.5)
    fixture.source.snapshot.apps[0].selectedDeviceUIDs = ["missing-device"]
    fixture.refresh()
    #expect(try fixture.text().contains { $0.contains("Unavailable") })
    let unavailable = try #require(fixture.presentation.subtitle)
    #expect(unavailable == "Unavailable (missing-device)")
    #expect(fixture.source.events.isEmpty)
  }
}

/// Centers of the four rendered route-menu buttons, in visual row order. The mode row is first,
/// then the System Audio and Output option rows; no fixture formula supplies a click point.
@MainActor
private func routeMenuTargets(in host: NSView) throws -> (
  single: CGPoint, multi: CGPoint, systemAudio: CGPoint, output: CGPoint
) {
  let frames = nativeButtonProxyFrames(in: host)
  #expect(frames.count == 4, "Two mode buttons and the two option rows each render once")
  let rows = renderedControlRows(frames, isFlipped: host.isFlipped)
  #expect(rows.count == 3, "The mode row and the System Audio/Output rows render separately")
  let modes = try #require(rows.first)
  #expect(modes.count == 2, "Single and Multi share the rendered mode row")
  let single = try #require(modes.first)
  let multi = try #require(modes.last)
  let systemAudio = try #require(rows.dropFirst().first?.first)
  let output = try #require(rows.dropFirst(2).first?.first)
  return (
    single: CGPoint(x: single.midX, y: single.midY),
    multi: CGPoint(x: multi.midX, y: multi.midY),
    systemAudio: CGPoint(x: systemAudio.midX, y: systemAudio.midY),
    output: CGPoint(x: output.midX, y: output.midY)
  )
}

@MainActor
@Observable
private final class AppRowState {
  var isEQExpanded = false
}

@MainActor
private final class AppRowFixture {
  let source = MixerTestSource()
  private let state = AppRowState()
  let host: NSHostingView<AnyView>
  let window: NSWindow
  /// The EQ toggle's rendered center as a distance from the host's visual top-left corner. The
  /// header keeps this position when the panel changes the fitted height.
  private var equalizerRowTarget: CGPoint?

  var isEQExpanded: Bool { state.isEQExpanded }

  var presentation: MixerAppRowPresentation {
    MixerAppRowPresentation(app: source.snapshot.apps[0], bindings: source.bindings)
  }

  init(
    size: MenuBarPopupSize, active: Bool, followingDefault: Bool = true,
    routeMenu: Bool = false, editing: Bool = false, appearance: AppearancePreference = .light
  ) {
    _ = NSApplication.shared
    source.snapshot.apps[0].isActive = active
    source.snapshot.apps[0].isFollowingDefault = followingDefault
    source.snapshot.apps[0].selectedDeviceUIDs = followingDefault ? [] : ["output-uid"]
    let source = source
    let state = state
    host = NSHostingView(
      rootView: AnyView(
        AppRowHarness(source: source, state: state, routeMenu: routeMenu, editing: editing)
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
    // A state change publishes its new intrinsic size during this pass; take it once more.
    host.layoutSubtreeIfNeeded()
    host.setFrameSize(host.fittingSize)
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
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

  /// Center of the row's EQ toggle in the actual 40pt header band. The panel grows the host below
  /// the fixed header, so the toggle keeps the same row-local position in both layouts. Resolve its
  /// rendered proxy once, while the collapsed header is stable, and reuse that row-local point for
  /// the closing click. The expanded header's proxy set can change while the row springs, so a
  /// second rightmost-proxy query can select the route picker instead of the EQ toggle.
  func equalizerTarget() throws -> CGPoint {
    let rowTarget: CGPoint
    if let equalizerRowTarget {
      rowTarget = equalizerRowTarget
    } else {
      // 28pt row content plus the row's 6pt vertical padding on each side.
      let headerHeight = DesignTokens.Dimensions.rowContentHeight + 12
      let header = CGRect(
        x: 0,
        y: host.isFlipped ? 0 : host.bounds.height - headerHeight,
        width: host.bounds.width,
        height: headerHeight
      )
      let frame = try #require(
        nativeButtonProxyFrames(in: host)
          .filter { header.contains(CGPoint(x: $0.midX, y: $0.midY)) }
          .max(by: { $0.midX < $1.midX }),
        "The rightmost rendered proxy inside the collapsed header band is the EQ toggle")
      rowTarget = CGPoint(x: frame.midX, y: visualTopY(frame.midY))
      equalizerRowTarget = rowTarget
    }
    return CGPoint(x: rowTarget.x, y: visualTopY(rowTarget.y))
  }

  /// Converts between a host y and a distance from the visual top edge. The header is pinned to
  /// that edge, so the same transform maps a settled row-local target into either layout.
  private func visualTopY(_ y: CGFloat) -> CGFloat {
    host.isFlipped ? y : host.bounds.height - y
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

  func show() throws {
    window.initialFirstResponder = host
    window.orderFrontRegardless()
    refresh()
    try #require(window.makeFirstResponder(host))
    #expect(source.events.allSatisfy { $0 == "app-volume" })
    source.events.removeAll()
  }

  func click(_ point: CGPoint, settleForLayout: Bool = false) throws {
    try sendMouseClick(in: window, at: host.convert(point, to: nil))
    if settleForLayout {
      settle()
    } else {
      refresh()
    }
  }

  /// SwiftUI applies the click's state change on the next run-loop turn and springs the new fitted
  /// height. Let the production spring settle before measuring that height or dispatching the next
  /// click; the fixed 0.4s run-loop interval covers the 0.35 response used by the EQ toggle.
  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    refresh()
  }
}

@MainActor
private struct AppRowHarness: View {
  let source: MixerTestSource
  let state: AppRowState
  var routeMenu = false
  var editing = false

  var body: some View {
    if routeMenu {
      MixerAppRouteMenu(
        app: source.snapshot.apps[0], bindings: source.bindings,
        dismiss: { source.events.append("dismiss") })
    } else {
      MixerAppRow(
        app: source.snapshot.apps[0], bindings: source.bindings, isEditing: editing,
        percentageDraft: nil,
        isEQExpanded: Binding(
          get: { state.isEQExpanded }, set: { state.isEQExpanded = $0 }))
    }
  }
}
