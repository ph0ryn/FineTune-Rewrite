// Actual production mixer, rendered into owned offscreen windows with fake actions only.
// Vision OCR checks visible copy in the actual popup bitmap; row geometry and actions use native
// control frames and dispatched events. Badge and idle-track styling use narrow deterministic pixel
// probes because SwiftUI draws those layers without a public non-pixel value.
import AppKit
import FineTuneDomain
import SwiftUI
import Testing
import Vision

@testable import FineTune

@Suite("Mixer control appearance", .serialized)
@MainActor
struct MixerControlAppearanceTests {
  @Test(
    "Device and application sliders have thin idle tracks, not persistent native thumbs",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious],
    [AppearancePreference.light, .dark])
  func idleTracks(size: MenuBarPopupSize, appearance: AppearancePreference) throws {
    let fixture = MixerControlFixture(size: size, appearance: appearance)
    let bitmap = try fixture.bitmap()
    try fixture.writeArtifact(bitmap, name: "mixer-\(size)-\(appearance)")
    let fields = controlDescendants(fixture.host).compactMap { $0 as? NSTextField }
      .filter(\.isEditable)
    try #require(fields.count == 2)
    var trackWidths: [CGFloat] = []
    for field in fields {
      let percentage = fixture.host.convert(field.bounds, from: field)
      let slider = CGRect(
        x: percentage.minX - DesignTokens.Spacing.sm - DesignTokens.Dimensions.sliderWidth,
        y: percentage.midY - 14, width: DesignTokens.Dimensions.sliderWidth, height: 28)
      // The production 4pt idle track is drawn without a public view value; this narrow height
      // probe asserts the documented slider silhouette.
      let accent = try accentSize(in: slider, bitmap: bitmap, host: fixture.host)
      #expect(accent.height >= 3 && accent.height <= 5, "Idle slider accent silhouette: \(accent)")
      trackWidths.append(accent.width)
    }
    #expect(abs(trackWidths[0] - trackWidths[1]) <= 1, "Device and app share the same slider width")
    #expect(!fixture.window.isVisible)
    #expect(fixture.source.events.isEmpty && fixture.source.profileSource.events.isEmpty)
  }

  @Test(
    "Observed input and output defaults have an accent badge that clears on a live default change",
    arguments: [MixerDeviceScope.output, .input], [AppearancePreference.light, .dark])
  func selectedDeviceBadge(scope: MixerDeviceScope, appearance: AppearancePreference) async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: appearance)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    if scope == .input {
      try fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let devices =
      scope == .output
      ? fixture.source.snapshot.outputDevices : fixture.source.snapshot.inputDevices
    let device = try #require(devices.first)
    // The row's production value is the observed default, which is exactly what the badge renders.
    #expect(fixture.source.bindings.deviceRow(device, scope: scope).isDefault)
    let selected = try fixture.bitmap()
    try fixture.writeArtifact(selected, name: "selected-device-\(scope)-\(appearance)")
    // The documented style values are asserted in AppPresentationContractTests; the focused pixel
    // probe here then proves the accent fill and white glyph actually reached the real bitmap.
    #expect(badgeFittingSize(isSelected: true) == CGSize(width: 28, height: 28))
    #expect(badgeFittingSize(isSelected: false) == CGSize(width: 28, height: 28))
    let selectedPercentage = try #require(fixture.percentageFrames().first)
    let selectedBadge = CGRect(
      x: padding, y: selectedPercentage.midY - 14, width: 28, height: 28)
    #expect(try badgeAccentArea(in: selectedBadge, bitmap: selected, host: fixture.host) > 250)
    #expect(
      try badgeWhiteGlyphArea(
        in: selectedBadge.insetBy(dx: 5, dy: 5), bitmap: selected, host: fixture.host) > 10)

    if scope == .output {
      fixture.source.snapshot.outputDevices[0].isDefault = false
    } else {
      fixture.source.snapshot.inputDevices[0].isDefault = false
    }
    fixture.refresh()
    let currentDevices =
      scope == .output
      ? fixture.source.snapshot.outputDevices : fixture.source.snapshot.inputDevices
    let current = try #require(currentDevices.first)
    #expect(!fixture.source.bindings.deviceRow(current, scope: scope).isDefault)
    let unselected = try fixture.bitmap()
    try fixture.writeArtifact(unselected, name: "unselected-device-\(scope)-\(appearance)")
    let currentPercentage = try #require(fixture.percentageFrames().first)
    let unselectedBadge = CGRect(
      x: padding, y: currentPercentage.midY - 14, width: 28, height: 28)
    #expect(try badgeAccentArea(in: unselectedBadge, bitmap: unselected, host: fixture.host) == 0)
    #expect(
      try badgeWhiteGlyphArea(
        in: unselectedBadge.insetBy(dx: 5, dy: 5), bitmap: unselected, host: fixture.host) == 0)
    #expect(fixture.source.events.isEmpty && fixture.source.profileSource.events.isEmpty)
  }

  @Test(
    "Native slider clicks still send scoped device and application gain actions, including muted rows",
    arguments: [false, true])
  func nativeSliderActions(muted: Bool) async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: .light, muted: muted)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let fields = fixture.percentageFrames()
    try #require(fields.count == 2)
    for (field, event) in zip(fields, ["device-volume", "app-volume"]) {
      try fixture.click(
        CGPoint(
          x: field.minX - DesignTokens.Spacing.sm - DesignTokens.Dimensions.sliderWidth / 4,
          y: field.midY))
      #expect(fixture.source.events.last == event)
      #expect(try #require(fixture.source.lastGain) > 0.25)
    }
    #expect(fixture.source.lastDeviceScope == .output)
    #expect(fixture.source.lastDeviceUID == "output-uid")
    #expect(fixture.source.lastAppID == "com.example.player")
    #expect(fixture.source.events == ["device-volume", "app-volume"])
  }

  @Test(
    "Device selection includes the name gap and whole-row vertical padding for both scopes",
    arguments: [MixerDeviceScope.output, .input],
    [MenuBarPopupSize.compact, .comfortable, .spacious])
  func deviceSelectionHitArea(scope: MixerDeviceScope, size: MenuBarPopupSize) async throws {
    let fixture = MixerControlFixture(size: size, appearance: .light)
    fixture.source.snapshot.outputDevices[0].isDefault = false
    fixture.source.snapshot.inputDevices[0].isDefault = false
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = size.dimensions.contentPadding
    if scope == .input {
      try fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let percentage = try #require(fixture.percentageFrames().first)
    // Positive control: a click on the existing name button reaches the same scoped action.
    try fixture.click(CGPoint(x: padding + 50, y: percentage.midY))
    #expect(fixture.source.events == ["default"])
    let muteLeft =
      percentage.minX - DesignTokens.Spacing.sm
      - DesignTokens.Dimensions.sliderWidth - DesignTokens.Spacing.sm
      - DesignTokens.Dimensions.minTouchTarget
    let blankPoints = [
      CGPoint(x: muteLeft - DesignTokens.Spacing.sm - 8, y: percentage.midY),
      CGPoint(x: padding + 12, y: percentage.midY - 17),
      CGPoint(x: padding + 12, y: percentage.midY + 17),
      CGPoint(x: percentage.minX - 70, y: percentage.midY + 17),
    ]
    for point in blankPoints {
      fixture.source.events.removeAll()
      try fixture.click(point)
      #expect(fixture.source.events == ["default"], "Non-control row point: \(point)")
      #expect(fixture.source.lastDeviceScope == scope)
      #expect(fixture.source.lastDeviceUID == (scope == .output ? "output-uid" : "input-uid"))
    }
  }

  @Test(
    "Controls in an unselected device row do not also switch the default device",
    arguments: [MixerDeviceScope.output, .input])
  func deviceControlsDoNotSelectRow(scope: MixerDeviceScope) async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: .light)
    fixture.source.snapshot.outputDevices[0].isDefault = false
    fixture.source.snapshot.inputDevices[0].isDefault = false
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    if scope == .input {
      try fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let percentage = try #require(fixture.percentageFrames().first)
    let sliderRight = percentage.minX - DesignTokens.Spacing.sm
    let muteX =
      sliderRight - DesignTokens.Dimensions.sliderWidth - DesignTokens.Spacing.sm
      - DesignTokens.Dimensions.minTouchTarget / 2
    try fixture.click(CGPoint(x: muteX, y: percentage.midY))
    #expect(fixture.source.events == ["device-mute"])
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: sliderRight - 35, y: percentage.midY))
    #expect(fixture.source.events == ["device-volume"])
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: percentage.midX, y: percentage.midY))
    // Native field focus can commit its unchanged value, but must never select the row.
    #expect(fixture.source.events.allSatisfy { $0 == "device-volume" })
    #expect(fixture.window.firstResponder is NSTextView)
    #expect(fixture.source.lastDeviceScope == scope)
  }

  @Test("An already-selected device row does not repeat its default-device command")
  func selectedDeviceClickIsNoOp() async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: .light)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let percentage = try #require(fixture.percentageFrames().first)
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    try fixture.click(CGPoint(x: padding + 50, y: percentage.midY))
    try fixture.click(CGPoint(x: padding + 12, y: percentage.midY + 17))
    #expect(fixture.source.events.isEmpty)
  }

  @Test(
    "App editing uses two compact columns with independent pin and visibility targets",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious])
  func appEditGrid(size: MenuBarPopupSize) async throws {
    let fixture = MixerControlFixture(size: size, appearance: .light)
    let source = fixture.source
    let padding = size.dimensions.contentPadding
    let contentWidth = size.dimensions.width - 2 * padding

    // The production two-column grid owns the wrap geometry; one row holds two apps and the next
    // row advances by the documented 40pt content plus 4pt spacing.
    func gridHeight(_ apps: [MixerAppPresentation]) -> CGFloat {
      NSHostingView(
        rootView: MixerAppEditGrid(apps: apps, bindings: source.bindings)
          .frame(width: contentWidth)
      ).fittingSize.height
    }
    let oneRow = gridHeight(editApps(source, names: ["Alpha"]))
    let twoApps = gridHeight(editApps(source, names: ["Alpha", "Beta"]))
    let threeApps = gridHeight(editApps(source, names: ["Alpha", "Beta", "Gamma"]))
    #expect(abs(twoApps - oneRow) <= 0.5, "Two compact columns keep two apps on one 40pt row")
    #expect(
      abs(threeApps - oneRow - 44) <= 0.5,
      "Each additional edit-grid row advances by 40pt content + 4pt spacing")
    #expect(source.events.isEmpty)

    // Render the actual production grid with the same two columns. The hit targets below are the
    // real rendered button proxies, not coordinates recomputed from a column-width formula.
    source.snapshot.apps = editApps(
      source, names: ["Alpha", "Beta", "Gamma", "Hidden", "Silent"],
      pinnedCount: 2, ignoredFrom: 3)
    // Gamma is inactive and unpinned: edit mode lists it, browse mode does not.
    source.snapshot.apps[2].isActive = false
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let width = fixture.host.bounds.width
    try fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    try fixture.writeArtifact(fixture.bitmap(), name: "app-edit-grid-\(size)")
    let text = try fixture.recognizedText().compactMap { $0.topCandidates(1).first?.string }
    let columnWidth = (width - 2 * padding - 4) / 2
    func named(_ name: String) throws -> CGRect {
      let rightColumn = name == "Beta" || name == "Silent"
      // Isolate real name pixels. Whole-row OCR merges columns and includes pin/eye glyph bounds.
      let region = CGRect(
        x: padding + (rightColumn ? columnWidth + 4 : 0) + 38, y: 0,
        width: columnWidth - 94, height: fixture.host.bounds.height)
      let candidates = try fixture.recognizedText(in: region)
      let observation = try #require(
        candidates.first { $0.topCandidates(1).first?.string == name },
        "Expected app \(name) in its visible name column")
      let bounds = observation.boundingBox
      return CGRect(
        x: region.minX + bounds.minX * region.width,
        y: (fixture.host.isFlipped ? 1 - bounds.maxY : bounds.minY) * region.height,
        width: bounds.width * region.width, height: bounds.height * region.height)
    }
    let alpha = try named("Alpha")
    let beta = try named("Beta")
    let gamma = try named("Gamma")
    let hidden = try named("Hidden")
    let silent = try named("Silent")
    #expect(text.contains { $0 == "APPS" })
    #expect(!text.contains { $0.contains("2 ignored") })
    // OCR ink bounds vary by glyph by about 2pt in the measured bitmaps, not by row layout.
    // Use 3pt OCR tolerance; AppRowPresentationTests independently checks the exact 40pt row.
    #expect(abs(alpha.minY - beta.minY) <= 3)
    #expect(beta.minX > width / 2)
    #expect(abs(gamma.minY - alpha.minY - 44) <= 3)
    // Low-contrast ignored labels get unequal OCR ink boxes. Classify the same 40pt row
    // by centers (< half a row), rather than treating those boxes as exact text baselines.
    #expect(abs(hidden.midY - silent.midY) < 20)
    #expect(hidden.minY > gamma.maxY)
    #expect(fixture.source.events.isEmpty)
    let editingSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings, editing: true)
    let nonEditingSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings)
    #expect(editingSemantics.sectionHeader == "APPS")
    #expect(editingSemantics.ignoredBadge == nil, "Reorder mode does not show the ignored count")
    #expect(editingSemantics.ignoredEmptyHint == nil)
    #expect(nonEditingSemantics.ignoredBadge == "2 ignored")
    // These are the exact raw lists the popup renders, in row order.
    #expect(editingSemantics.apps.map(\.id) == ["app-Alpha", "app-Beta", "app-Gamma"])
    #expect(nonEditingSemantics.apps.map(\.id) == ["app-Alpha", "app-Beta"])
    #expect(editingSemantics.ignoredApps.map(\.id) == ["app-Hidden", "app-Silent"])
    let grid = AppEditGridFixture(
      source: source, active: editingSemantics.apps,
      ignored: editingSemantics.ignoredApps, width: contentWidth)
    grid.show()
    defer { grid.window.orderOut(nil) }
    let frames = nativeButtonProxyFrames(in: grid.host)
    let rows = gridRows(frames)
    #expect(rows.count == 3)
    #expect(rows[0].count == 4, "Alpha and Beta each own pin and eye targets")
    #expect(rows[1].count == 2, "Gamma is the second row's left column")
    #expect(rows[2].count == 2, "Ignored rows own the eye target only")

    let alphaPin = try #require(rows[0].first)
    let alphaEye = try #require(rows[0].dropFirst().first)
    let betaPin = try #require(rows[0].dropFirst(2).first)
    let betaEye = try #require(rows[0].dropFirst(3).first)
    #expect(abs(alphaPin.midY - alphaEye.midY) < 2)
    #expect(alphaPin.minX < betaPin.minX, "The second app is in the second rendered column")
    try grid.click(alphaPin)
    #expect(source.events == ["pin"])
    #expect(source.lastAppID == "app-Alpha" && source.lastBool == false)
    source.events.removeAll()
    try grid.click(alphaEye)
    #expect(source.events == ["ignore"])
    #expect(source.lastAppID == "app-Alpha" && source.lastBool == true)
    source.events.removeAll()
    try grid.click(betaPin)
    #expect(source.events == ["pin"])
    #expect(source.lastAppID == "app-Beta" && source.lastBool == false)
    source.events.removeAll()
    try grid.click(betaEye)
    #expect(source.events == ["ignore"])
    #expect(source.lastAppID == "app-Beta")
    source.events.removeAll()

    let hiddenEye = try #require(rows[2].first)
    try grid.click(hiddenEye)
    #expect(source.events == ["ignore"])
    #expect(source.lastAppID == "app-Hidden" && source.lastBool == false)
    #expect(!source.events.contains("default"), "Edit controls never select a device or row")
    #expect(source.events.allSatisfy { $0 == "pin" || $0 == "ignore" })
  }

  @Test("Icon tabs, edit, retry, settings and footer Quit retain their actual pointer actions")
  func chromeActions() async throws {
    let fixture = MixerControlFixture(size: .compact, appearance: .light)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.compact.dimensions.contentPadding
    let width = fixture.host.bounds.width
    // The original header's explicit 26pt tabs and 16pt action columns provide stable hit points.
    try fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    let input = try #require(fixture.percentageFrames().first)
    try fixture.click(
      CGPoint(x: input.minX - DesignTokens.Spacing.sm - 35, y: input.midY))
    #expect(fixture.source.lastDeviceScope == .input)
    #expect(fixture.source.lastDeviceUID == "input-uid")
    try fixture.click(CGPoint(x: padding + 16, y: padding + 16))
    let output = try #require(fixture.percentageFrames().first)
    try fixture.click(
      CGPoint(x: output.minX - DesignTokens.Spacing.sm - 35, y: output.midY))
    #expect(fixture.source.lastDeviceScope == .output)
    try fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(fixture.editableFields.contains { $0.stringValue == "1" })
    try fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(!fixture.editableFields.contains { $0.stringValue == "1" })
    try fixture.click(CGPoint(x: width - padding - 32, y: padding + 8))
    try fixture.click(CGPoint(x: width - padding - 8, y: padding + 8))
    try fixture.click(
      CGPoint(x: width - padding - 30, y: fixture.host.bounds.height - padding - 10))
    #expect(
      fixture.source.events == [
        "device-volume", "device-volume", "capture-request", "settings", "quit",
      ])
  }

  @Test("The header uses icon controls rather than raw Edit text or a Devices picker label")
  func compactIconHeader() throws {
    let fixture = MixerControlFixture(size: .compact, appearance: .light)
    let semantics = MixerPopupSemantics(
      snapshot: fixture.source.snapshot, bindings: fixture.source.bindings)
    #expect(semantics.inputName == "Input")
    let renderedText = try fixture.recognizedText().compactMap { $0.topCandidates(1).first?.string }
    #expect(renderedText.contains { $0.contains("APPS") })
    #expect(!renderedText.contains { $0.localizedCaseInsensitiveContains("Edit") })
    #expect(!renderedText.contains { $0.localizedCaseInsensitiveContains("Devices") })
    // Semantic assertions independently lock the production copy sources.
    #expect(semantics.sectionHeader == "APPS")
    // The exact header strings and allStrings purity are asserted in
    // AppPresentationContractTests; this rendered header keeps the OCR and control checks below.
    #expect(!controlDescendants(fixture.host).contains { $0 is NSPopUpButton })
    // The popup always renders two editable volume percentage columns, one in the device row and
    // one in the application row, both owned by the production `VolumePercentageField`. They are
    // unrelated to the header, so the header contract is checked against the production header's
    // own band rather than the whole popup.
    let padding = MenuBarPopupSize.compact.dimensions.contentPadding
    let contentWidth = MenuBarPopupSize.compact.dimensions.width - 2 * padding
    let headerHeight = NSHostingView(
      rootView: MixerHeader(
        scope: .constant(.output), isEditing: false,
        outputName: semantics.outputName, inputName: semantics.inputName,
        edit: {}, retryAudio: {}, settings: {}
      )
      .frame(width: contentWidth)
    ).fittingSize.height
    #expect(headerHeight > 0)
    let headerTop: CGFloat
    if fixture.host.isFlipped {
      headerTop = padding
    } else {
      headerTop = fixture.host.bounds.height - padding - headerHeight
    }
    let headerBand = CGRect(x: padding, y: headerTop, width: contentWidth, height: headerHeight)
    let fieldFrames = fixture.editableFields.map { fixture.host.convert($0.bounds, from: $0) }
    #expect(fieldFrames.count == 2, "Only the two volume percentage columns are editable")
    #expect(
      fieldFrames.allSatisfy { !$0.intersects(headerBand) },
      "No editable text field belongs to the icon-only header")
    #expect(fixture.source.events.isEmpty)
    try fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    // Switch to Input and OCR only the rendered header band to verify the projected input device
    // name reaches visible glyphs, not just the semantic copy value.
    try fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    let inputHeaderText = try fixture.recognizedText(in: headerBand).compactMap {
      $0.topCandidates(1).first?.string
    }
    #expect(inputHeaderText.contains { $0.contains("Input") })
    try fixture.click(CGPoint(x: padding + 16, y: padding + 16))
    let width = fixture.host.bounds.width
    // The header's action columns are icon buttons, not a raw "Edit" text or Devices picker.
    try fixture.click(CGPoint(x: width - padding - 32, y: padding + 8))
    try fixture.click(CGPoint(x: width - padding - 8, y: padding + 8))
    #expect(fixture.source.events == ["capture-request", "settings"])
    fixture.source.events.removeAll()
    try fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(fixture.editableFields.contains { $0.stringValue == "1" })
    try fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(!fixture.editableFields.contains { $0.stringValue == "1" })
    #expect(fixture.source.events.isEmpty)
  }
}

@MainActor
private func editApps(
  _ source: MixerTestSource, names: [String], pinnedCount: Int = 0, ignoredFrom: Int? = nil
) -> [MixerAppPresentation] {
  let seed = source.snapshot.apps[0]
  return names.enumerated().map { index, name in
    var app = seed
    app.id = "app-\(name)"
    app.name = name
    app.isActive = true
    app.isPinned = index < pinnedCount
    app.isIgnored = ignoredFrom.map { index >= $0 } ?? false
    return app
  }
}

@MainActor
private func gridRows(_ frames: [CGRect]) -> [[CGRect]] {
  var rows: [[CGRect]] = []
  for frame in frames.sorted(by: { $0.midY < $1.midY }) {
    if let last = rows.last, let reference = last.first, abs(reference.midY - frame.midY) <= 1 {
      rows[rows.count - 1].append(frame)
    } else {
      rows.append([frame])
    }
  }
  return rows.map { $0.sorted { $0.minX < $1.minX } }
}

@MainActor
private final class AppEditGridFixture {
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(
    source: MixerTestSource, active: [MixerAppPresentation], ignored: [MixerAppPresentation],
    width: CGFloat
  ) {
    _ = NSApplication.shared
    host = NSHostingView(
      rootView: AnyView(
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          MixerAppEditGrid(apps: active, bindings: source.bindings)
          if !ignored.isEmpty {
            MixerAppEditGrid(apps: ignored, bindings: source.bindings)
          }
        }
        .frame(width: width)
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor))))
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.setFrameSize(host.fittingSize)
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  isolated deinit { window.close() }

  func show() {
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  func click(_ frame: CGRect) throws {
    try sendMouseClick(in: window, at: host.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil))
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }
}

@MainActor
private final class MixerControlFixture {
  let source = MixerTestSource()
  let size: MenuBarPopupSize
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(size: MenuBarPopupSize, appearance: AppearancePreference, muted: Bool = false) {
    _ = NSApplication.shared
    self.size = size
    source.snapshot.settings.popupSize = size
    source.snapshot.settings.appearance = appearance
    source.snapshot.outputDevices[0].isMuted = muted
    source.snapshot.apps[0].isMuted = muted
    let source = source
    let colorScheme: ColorScheme = appearance == .dark ? .dark : .light
    host = NSHostingView(
      rootView: AnyView(
        MixerView(
          read: { source.snapshot }, actions: source.actions,
          profiles: source.profileSource.interface, quit: { source.events.append("quit") }
        )
        .accentColor(.blue)
        .environment(\.controlActiveState, .active)
        .environment(\.colorScheme, colorScheme)
        .background(Color(nsColor: .windowBackgroundColor))))
    let nativeAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    host.appearance = nativeAppearance
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = nativeAppearance
    window.contentView = host
    refresh()
  }

  isolated deinit { window.close() }

  var editableFields: [NSTextField] {
    controlDescendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
  }

  func percentageFrames() -> [CGRect] {
    editableFields.map { host.convert($0.bounds, from: $0) }.sorted {
      host.isFlipped ? $0.midY < $1.midY : $0.midY > $1.midY
    }
  }

  func refresh() {
    // Establish the fixed popup width, flush observation-driven body updates, then take the
    // intrinsic height. NSHostingView lays out synchronously in this test process.
    host.setFrameSize(NSSize(width: size.dimensions.width, height: host.frame.height))
    host.layoutSubtreeIfNeeded()
    host.setFrameSize(NSSize(width: size.dimensions.width, height: host.fittingSize.height))
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  func showForPointerInput() throws {
    // Order only this fixture's window, still at -10,000pt, without activating any application.
    window.orderFrontRegardless()
    refresh()
  }

  func click(_ point: CGPoint) throws {
    try sendMouseClick(in: window, at: host.convert(point, to: nil))
    refresh()
  }

  func bitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  func recognizedText(in region: CGRect? = nil) throws -> [VNRecognizedTextObservation] {
    let image = try #require(bitmap().cgImage)
    let input: CGImage
    if let region {
      let scaleX = CGFloat(image.width) / host.bounds.width
      let scaleY = CGFloat(image.height) / host.bounds.height
      let top = host.isFlipped ? region.minY : host.bounds.height - region.maxY
      input = try #require(
        image.cropping(
          to: CGRect(
            x: region.minX * scaleX, y: top * scaleY,
            width: region.width * scaleX, height: region.height * scaleY)))
    } else {
      input = image
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
    return request.results ?? []
  }

  func writeArtifact(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["FINETUNE_MIXER_CONTROL_EVIDENCE"]
    else { return }
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: destination.appendingPathComponent("\(name).png"))
  }
}

@MainActor
private func controlDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + controlDescendants($0) }
}

@MainActor
private func accentSize(in rect: CGRect, bitmap: NSBitmapImageRep, host: NSView) throws -> CGSize {
  let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
  let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
  let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
  let xs = Int((rect.minX + 2) * scaleX)..<Int((rect.maxX - 2) * scaleX)
  let ys = Int(top * scaleY)..<Int((top + rect.height) * scaleY)
  try #require(xs.lowerBound >= 0 && xs.upperBound <= bitmap.pixelsWide)
  try #require(ys.lowerBound >= 0 && ys.upperBound <= bitmap.pixelsHigh)
  var pixels: [CGPoint] = []
  for y in ys {
    for x in xs {
      let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      if color.blueComponent > color.redComponent + 0.25
        && color.blueComponent > color.greenComponent + 0.1
      {
        pixels.append(CGPoint(x: x, y: y))
      }
    }
  }
  let minX = try #require(pixels.map(\.x).min(), "Slider accent must be visible")
  let maxX = try #require(pixels.map(\.x).max())
  let minY = try #require(pixels.map(\.y).min())
  let maxY = try #require(pixels.map(\.y).max())
  return CGSize(width: (maxX - minX + 1) / scaleX, height: (maxY - minY + 1) / scaleY)
}
