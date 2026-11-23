// Production MixerView rendered in priority-edit mode. The gate asserts control structure with
// AppKit-visible native fields; representative bitmaps are written for human review only.
// No OCR, pixel probes, private SwiftUI proxies, or pointer event loops.
import AppKit
import FineTuneDomain
import SwiftUI
import Testing

@testable import FineTune

@Suite("Priority edit row layout")
@MainActor
struct DeviceEditRowLayoutTests {
  @Test(
    "Edit rows expose no volume or priority text fields",
    arguments: [MenuBarPopupSize.compact, .comfortable, .spacious])
  func editRowsDropVolumeControls(size: MenuBarPopupSize) throws {
    let source = editSource(size: size)
    let fixture = try EditPopupFixture(source: source)
    try fixture.writeArtifact("priority-edit-\(size)")
    #expect(fixture.textFields.isEmpty)
    #expect(fixture.host.frame.width == size.dimensions.width)
    #expect(source.events.isEmpty && source.profileSource.events.isEmpty)
    #expect(!fixture.window.isVisible)
  }
}

@MainActor
private func editSource(size: MenuBarPopupSize) -> MixerTestSource {
  let source = MixerTestSource()
  source.snapshot.settings.popupSize = size
  source.snapshot.settings.appearance = .light
  source.snapshot.apps = []
  let original = source.snapshot.outputDevices[0]
  source.snapshot.outputDevices[0].device = AudioDevice(
    id: 801, uid: "edit-speakers", name: "MacBook Air built-in speakers", icon: nil,
    supportsAutoEQ: false)
  var headphones = original
  headphones.device = AudioDevice(
    id: 802, uid: "edit-headphones", name: "Wireless headphones", icon: nil,
    supportsAutoEQ: false)
  headphones.isDefault = false
  source.snapshot.outputDevices.append(headphones)
  return source
}

@MainActor
private final class EditPopupFixture {
  let source: MixerTestSource
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(source: MixerTestSource) throws {
    _ = NSApplication.shared
    self.source = source
    host = NSHostingView(
      rootView: AnyView(
        MixerView(
          read: { source.snapshot }, actions: source.actions,
          profiles: source.profileSource.interface,
          quit: { source.events.append("quit") }, initialEditing: true
        )
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor))))
    host.appearance = NSAppearance(named: .aqua)
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.setFrameSize(
      NSSize(
        width: source.snapshot.settings.popupSize.dimensions.width,
        height: host.fittingSize.height))
    window.setContentSize(host.frame.size)
    host.layoutSubtreeIfNeeded()
  }

  var textFields: [NSTextField] {
    editDescendants(host).compactMap { $0 as? NSTextField }
  }

  func writeArtifact(_ name: String) throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "FINETUNE_EDIT_ROW_ARTIFACT_DIRECTORY"]
    else { return }
    let destination = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: destination.appendingPathComponent("\(name).png"))
  }
}

@MainActor
private func editDescendants(_ view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + editDescendants($0) }
}
