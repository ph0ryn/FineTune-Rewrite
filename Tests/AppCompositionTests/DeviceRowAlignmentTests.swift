// Actual production MixerView with fake ports and never-ordered-in own windows.
// Percent columns use real native fields. Slider/mute alignment is reviewed in the same bitmaps
// together with the production fixed adjacent-column constraints, not native/AX slider frames.
// No Root, audio/device runtime, persistence, permissions, native key events, or external apps.
import AppKit
import FineTuneDomain
import FineTunePlatform
import SwiftUI
import Testing

@testable import FineTune

@Suite("Shared device row columns")
@MainActor
struct DeviceRowAlignmentTests {
  @Test(
    "AutoEQ availability does not move the actual percentage column",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious])
  func autoEQAvailabilityKeepsPercentageColumn(size: MenuBarPopupSize) throws {
    let source = alignmentSource(size: size)
    let fixture = try DeviceAlignmentFixture(source: source)
    try fixture.writeArtifact("mixed-\(size)")
    let columns = try fixture.percentageColumns(expectedCount: 2)
    print("Mixed AutoEQ \(size) actual percentage frames: \(columns)")
    assertSamePercentageColumn(columns[0], columns[1])
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
    #expect(!fixture.window.isVisible)
  }

  @Test(
    "A selected profile and default checkmark retain the percentage column and full-row bitmap",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious])
  func profileAndDefaultChangesKeepPercentageColumn(size: MenuBarPopupSize) throws {
    let source = alignmentSource(size: size)
    source.snapshot.outputDevices.removeFirst()
    let fixture = try DeviceAlignmentFixture(source: source)
    try fixture.writeArtifact("before-selection-\(size)")
    let before = try #require(fixture.percentageColumns(expectedCount: 1).first)

    source.profileSource.snapshot.selection = AutoEQSelection(
      profileID: "alignment-profile", isEnabled: true)
    source.profileSource.snapshot.profileName =
      "A deliberately long headphone correction profile that must remain inside its name column"
    source.snapshot.outputDevices[0].isDefault = true
    source.snapshot.outputDevices[0].volume = 0.36
    try fixture.refresh()
    try fixture.writeArtifact("after-selection-\(size)")
    let after = try #require(fixture.percentageColumns(expectedCount: 1).first)
    // percentageColumns also verifies the updated 60% value, ruling out stale view geometry.
    print("Selected profile \(size) actual percentage frames: before=\(before), after=\(after)")
    assertSamePercentageColumn(before, after)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
    #expect(!fixture.window.isVisible)
  }
}

@MainActor
private func assertSamePercentageColumn(_ first: CGRect, _ second: CGRect) {
  #expect(abs(first.minX - second.minX) <= 0.5)
  #expect(abs(first.maxX - second.maxX) <= 0.5)
  #expect(abs(first.width - second.width) <= 0.5)
}

@MainActor
private func alignmentSource(size: MenuBarPopupSize) -> MixerTestSource {
  let source = MixerTestSource()
  source.snapshot.settings.popupSize = size
  source.snapshot.settings.appearance = .light
  source.snapshot.apps = []
  var speakers = source.snapshot.outputDevices[0]
  speakers.device = AudioDevice(
    id: 801, uid: "alignment-speakers", name: "MacBook Air built-in speakers", icon: nil,
    supportsAutoEQ: false)
  speakers.isDefault = true
  var headphones = speakers
  headphones.device = AudioDevice(
    id: 802, uid: "alignment-headphones", name: "Wireless headphones", icon: nil,
    supportsAutoEQ: true)
  headphones.isDefault = false
  source.snapshot.outputDevices = [speakers, headphones]
  return source
}

@MainActor
private final class DeviceAlignmentFixture {
  let source: MixerTestSource
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(source: MixerTestSource) throws {
    _ = NSApplication.shared
    self.source = source
    host = NSHostingView(rootView: Self.mixer(source))
    host.appearance = NSAppearance(named: .aqua)
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    try refresh()
  }

  func refresh() throws {
    host.rootView = Self.mixer(source)
    let width = source.snapshot.settings.popupSize.dimensions.width
    host.setFrameSize(NSSize(width: width, height: host.fittingSize.height))
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
    _ = try bitmap()
  }

  func percentageColumns(expectedCount: Int) throws -> [CGRect] {
    let fields = alignmentDescendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    try #require(fields.count == expectedCount)
    let expectedValues = source.snapshot.outputDevices.map { row in
      row.volume.map {
        DeviceRow.volumeToSlider($0, backend: row.backend)
          .formatted(.percent.precision(.fractionLength(0)))
      }
    }
    #expect(fields.map(\.stringValue).sorted() == expectedValues.compactMap { $0 }.sorted())
    let frames = fields.map { host.convert($0.bounds, from: $0) }.sorted { $0.midY < $1.midY }
    for frame in frames {
      #expect(frame.width > 0 && frame.height > 0)
      #expect(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame))
    }
    return frames
  }

  func writeArtifact(_ name: String) throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "FINETUNE_DEVICE_ALIGNMENT_ARTIFACT_DIRECTORY"]
    else { return }
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let image = try bitmap()
    let png = try #require(image.representation(using: .png, properties: [:]))
    try png.write(to: destination.appendingPathComponent("\(name).png"))
  }

  private func bitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  private static func mixer(_ source: MixerTestSource) -> AnyView {
    // Opaque test-only canvas makes the same production content readable without native glass.
    AnyView(
      MixerView(
        read: { source.snapshot }, actions: source.actions,
        profiles: source.profileSource.interface,
        quit: { source.events.append("quit") }
      )
      .environment(\.colorScheme, .light)
      .background(Color(nsColor: .windowBackgroundColor)))
  }
}

@MainActor
private func alignmentDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + alignmentDescendants($0) }
}
