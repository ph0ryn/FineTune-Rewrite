import AppKit
import FineTuneDomain
import SwiftUI
import Testing

@testable import FineTune

/// Guards the EQ-open regression: one render pass must not rebuild the whole mixer snapshot
/// once per slider. Counts the production `read` entry point, not private view internals.
@Suite("EQ expansion read-through cost")
@MainActor
struct EQRenderReadCountTests {
  @Test("Expanding the EQ panel does not multiply full snapshot reads")
  func expandingEQDoesNotMultiplyReads() throws {
    _ = NSApplication.shared
    let collapsed = readCount(expanded: false)
    let expanded = readCount(expanded: true)
    #expect(
      collapsed <= 10 && expanded <= 10,
      "one read per body pass, independent of EQ: collapsed=\(collapsed) expanded=\(expanded)")
  }

  private func readCount(expanded: Bool) -> Int {
    let source = MixerTestSource()
    var reads = 0
    let view = MixerView(
      read: {
        reads += 1
        return source.snapshot
      },
      actions: source.actions,
      profiles: source.profileSource.interface,
      quit: {},
      initialExpandedAppID: expanded ? source.snapshot.apps[0].id : nil)
    let popover = MenuBarPresentation.makePopover(content: view)
    popover.contentViewController?.view.layoutSubtreeIfNeeded()
    return reads
  }
}
