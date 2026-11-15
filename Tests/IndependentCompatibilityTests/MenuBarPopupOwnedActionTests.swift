// Independently authored coverage for the app-owned status item action.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AppKit
import Testing

@testable import FineTune

@Suite("MenuBarPopupController")
@MainActor
struct MenuBarPopupControllerTests {
  // Materialize NSApp before the test creates a real status-item window.
  init() { _ = NSApplication.shared }

  @Test("Rewrite: an app-owned status item toggles its real presentation action")
  func ownedStatusItemAction() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let controller = MenuBarPopupController()
    var toggles = 0
    controller.attach(statusItem: item) { toggles += 1 }
    #expect(controller.findStatusItem() === item)
    controller.toggle()
    controller.toggle()
    #expect(toggles == 2)
  }
}
