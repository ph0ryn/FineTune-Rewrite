// Actual production mixer, rendered into owned offscreen windows with fake actions only.
// The bitmap checks the visible slider silhouette, not private SwiftUI view structure.
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
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    if scope == .input {
      try await fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let percentage = try #require(fixture.percentageFrames().first)
    let badge = CGRect(x: padding, y: percentage.midY - 14, width: 28, height: 28)
    let selected = try fixture.bitmap()
    try fixture.writeArtifact(selected, name: "selected-device-\(scope)-\(appearance)")
    #expect(try badgeAccentArea(in: badge, bitmap: selected, host: fixture.host) > 250)

    if scope == .output {
      fixture.source.snapshot.outputDevices[0].isDefault = false
    } else {
      fixture.source.snapshot.inputDevices[0].isDefault = false
    }
    try await fixture.settle()
    let unselected = try fixture.bitmap()
    try fixture.writeArtifact(unselected, name: "unselected-device-\(scope)-\(appearance)")
    #expect(try badgeAccentArea(in: badge, bitmap: unselected, host: fixture.host) == 0)
    #expect(fixture.source.events.isEmpty && fixture.source.profileSource.events.isEmpty)
  }

  @Test(
    "Native slider clicks still send scoped device and application gain actions, including muted rows",
    arguments: [false, true])
  func nativeSliderActions(muted: Bool) async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: .light, muted: muted)
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let fields = fixture.percentageFrames()
    try #require(fields.count == 2)
    for (field, event) in zip(fields, ["device-volume", "app-volume"]) {
      try await fixture.click(
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
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = size.dimensions.contentPadding
    if scope == .input {
      try await fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let percentage = try #require(fixture.percentageFrames().first)
    // Positive control: a click on the existing name button reaches the same scoped action.
    try await fixture.click(CGPoint(x: padding + 50, y: percentage.midY))
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
      try await fixture.click(point)
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
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    if scope == .input {
      try await fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    }
    let percentage = try #require(fixture.percentageFrames().first)
    let sliderRight = percentage.minX - DesignTokens.Spacing.sm
    let muteX =
      sliderRight - DesignTokens.Dimensions.sliderWidth - DesignTokens.Spacing.sm
      - DesignTokens.Dimensions.minTouchTarget / 2
    try await fixture.click(CGPoint(x: muteX, y: percentage.midY))
    #expect(fixture.source.events == ["device-mute"])
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: sliderRight - 35, y: percentage.midY))
    #expect(fixture.source.events == ["device-volume"])
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: percentage.midX, y: percentage.midY))
    // Native field focus can commit its unchanged value, but must never select the row.
    #expect(fixture.source.events.allSatisfy { $0 == "device-volume" })
    #expect(fixture.window.firstResponder is NSTextView)
    #expect(fixture.source.lastDeviceScope == scope)
  }

  @Test("An already-selected device row does not repeat its default-device command")
  func selectedDeviceClickIsNoOp() async throws {
    let fixture = MixerControlFixture(size: .comfortable, appearance: .light)
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let percentage = try #require(fixture.percentageFrames().first)
    let padding = MenuBarPopupSize.comfortable.dimensions.contentPadding
    try await fixture.click(CGPoint(x: padding + 50, y: percentage.midY))
    try await fixture.click(CGPoint(x: padding + 12, y: percentage.midY + 17))
    #expect(fixture.source.events.isEmpty)
  }

  @Test(
    "App editing uses two compact columns with independent pin and visibility targets",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious])
  func appEditGrid(size: MenuBarPopupSize) async throws {
    let fixture = MixerControlFixture(size: size, appearance: .light)
    let seed = fixture.source.snapshot.apps[0]
    fixture.source.snapshot.apps = ["Alpha", "Beta", "Gamma", "Hidden", "Silent"].enumerated().map {
      index, name in
      var app = seed
      app.id = "app-\(name)"
      app.name = name
      app.isActive = true
      app.isPinned = index < 2
      app.isIgnored = index >= 3
      return app
    }
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = size.dimensions.contentPadding
    let width = fixture.host.bounds.width
    try await fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
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

    try await fixture.click(CGPoint(x: padding + columnWidth - 40, y: alpha.midY))
    #expect(fixture.source.events == ["pin"])
    #expect(fixture.source.lastAppID == "app-Alpha" && fixture.source.lastBool == false)
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: padding + columnWidth - 16, y: alpha.midY))
    #expect(fixture.source.events == ["ignore"])
    #expect(fixture.source.lastAppID == "app-Alpha" && fixture.source.lastBool == true)
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: width - padding - 16, y: beta.midY))
    #expect(fixture.source.events == ["ignore"])
    #expect(fixture.source.lastAppID == "app-Beta")
    fixture.source.events.removeAll()
    try await fixture.click(CGPoint(x: padding + columnWidth - 40, y: hidden.midY))
    #expect(fixture.source.events.isEmpty, "Ignored rows have no pin button")
    try await fixture.click(CGPoint(x: padding + columnWidth - 16, y: hidden.midY))
    #expect(fixture.source.events == ["ignore"])
    #expect(fixture.source.lastAppID == "app-Hidden" && fixture.source.lastBool == false)
  }

  @Test("Icon tabs, edit, retry, settings and footer Quit retain their actual pointer actions")
  func chromeActions() async throws {
    let fixture = MixerControlFixture(size: .compact, appearance: .light)
    try await fixture.showForPointerInput()
    defer { fixture.window.orderOut(nil) }
    let padding = MenuBarPopupSize.compact.dimensions.contentPadding
    let width = fixture.host.bounds.width
    // The original header's explicit 26pt tabs and 16pt action columns provide stable hit points.
    try await fixture.click(CGPoint(x: padding + 44, y: padding + 16))
    let input = try #require(fixture.percentageFrames().first)
    try await fixture.click(
      CGPoint(x: input.minX - DesignTokens.Spacing.sm - 35, y: input.midY))
    #expect(fixture.source.lastDeviceScope == .input)
    #expect(fixture.source.lastDeviceUID == "input-uid")
    try await fixture.click(CGPoint(x: padding + 16, y: padding + 16))
    let output = try #require(fixture.percentageFrames().first)
    try await fixture.click(
      CGPoint(x: output.minX - DesignTokens.Spacing.sm - 35, y: output.midY))
    #expect(fixture.source.lastDeviceScope == .output)
    try await fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(fixture.editableFields.contains { $0.stringValue == "1" })
    try await fixture.click(CGPoint(x: width - padding - 56, y: padding + 8))
    #expect(!fixture.editableFields.contains { $0.stringValue == "1" })
    try await fixture.click(CGPoint(x: width - padding - 32, y: padding + 8))
    try await fixture.click(CGPoint(x: width - padding - 8, y: padding + 8))
    try await fixture.click(
      CGPoint(x: width - padding - 30, y: fixture.host.bounds.height - padding - 10))
    #expect(
      fixture.source.events == [
        "device-volume", "device-volume", "capture-request", "settings", "quit",
      ])
  }

  @Test("The header uses icon controls rather than raw Edit text or a Devices picker label")
  func compactIconHeader() throws {
    let fixture = MixerControlFixture(size: .compact, appearance: .light)
    let text = try fixture.recognizedText().compactMap { $0.topCandidates(1).first?.string }
    #expect(text.contains { $0 == "APPS" })
    #expect(!text.contains { $0 == "Edit" || $0 == "Devices" })
    #expect(fixture.source.events.isEmpty)
  }
}

@MainActor
private final class MixerControlFixture {
  let source = MixerTestSource()
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(size: MenuBarPopupSize, appearance: AppearancePreference, muted: Bool = false) {
    _ = NSApplication.shared
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
    host.setFrameSize(NSSize(width: size.dimensions.width, height: host.fittingSize.height))
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
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

  func showForPointerInput() async throws {
    // Order only this fixture's window, still at -10,000pt, without activating any application.
    window.orderFrontRegardless()
    try await settle()
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

  func settle() async throws {
    // One bounded display-cycle wait per input, matching the existing native-popup fixtures.
    try await Task.sleep(for: .milliseconds(120))
    host.setFrameSize(NSSize(width: host.bounds.width, height: host.fittingSize.height))
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
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
