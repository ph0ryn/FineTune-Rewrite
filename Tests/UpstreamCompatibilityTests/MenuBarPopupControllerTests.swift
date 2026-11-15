import AppKit
// SPDX-License-Identifier: GPL-3.0-only
// Derived from ronitsingh10/FineTune at 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Original assertions/inputs retained. Environment adaptation: NSApplication.shared in suite init.
// FineTuneTests/MenuBarPopupControllerTests.swift
import Testing

@testable import FineTune

@Suite("MenuBarPopupController", .serialized)
@MainActor
struct MenuBarPopupControllerTests {
  // Environment adaptation: materialize NSApp before creating real status-item windows.
  init() { _ = NSApplication.shared }
  @Test("toggle is a no-op when no matching status item exists")
  func noMatchingItem() {
    // Use a deliberately unique accessibility title so no real status item
    // (e.g. one materialized by another concurrently-running test) can match.
    let controller = MenuBarPopupController(
      accessibilityTitle: "FineTuneTest-NoSuchItem-\(UUID().uuidString)")
    controller.toggle()  // must not crash; logs a debug message and returns
  }

  @Test("findStatusItem returns nil when no matching status item exists")
  func findReturnsNilWhenNoMatch() {
    let controller = MenuBarPopupController(
      accessibilityTitle: "FineTuneTest-NoSuchItem-\(UUID().uuidString)")
    #expect(controller.findStatusItem() == nil)
  }

  @Test("findStatusItem locates the matching status item by accessibility title")
  func findLocatesMatching() {
    let title = "FineTuneTest-Match-\(UUID().uuidString)"
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.setAccessibilityTitle(title)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }

    // Materialize the button window so KVC has a fully-formed window to walk.
    _ = statusItem.button?.window?.windowNumber

    let controller = MenuBarPopupController(accessibilityTitle: title)
    let found = controller.findStatusItem()

    #expect(found === statusItem)
  }

  @Test("findStatusItem ignores items with non-matching accessibility titles")
  func findIgnoresNonMatching() {
    let otherTitle = "FineTuneTest-Other-\(UUID().uuidString)"
    let other = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    other.button?.setAccessibilityTitle(otherTitle)
    defer { NSStatusBar.system.removeStatusItem(other) }
    _ = other.button?.window?.windowNumber

    let controller = MenuBarPopupController(
      accessibilityTitle: "FineTuneTest-Searching-\(UUID().uuidString)")
    #expect(controller.findStatusItem() == nil)
  }

  @Test("toggle on a discovered status item runs to completion without crashing")
  func toggleEndToEndSmoke() throws {
    // Adapted to the delivery seam: exercise real discovery and event construction,
    // then assert the intended event without relying on the test process's AppKit pump.
    // The production default still activates the app and posts the event.
    let title = "FineTuneTest-Smoke-\(UUID().uuidString)"
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.setAccessibilityTitle(title)
    defer { NSStatusBar.system.removeStatusItem(statusItem) }
    let button = try #require(statusItem.button)
    let window = try #require(button.window)

    var events: [NSEvent] = []
    let controller = MenuBarPopupController(
      accessibilityTitle: title, eventPoster: { events.append($0) })
    controller.toggle()
    #expect(events.count == 1)
    #expect(events.first?.type == .leftMouseDown)
    #expect(events.first?.windowNumber == window.windowNumber)
    #expect(events.first?.locationInWindow == NSPoint(x: button.bounds.midX, y: button.bounds.midY))
  }

}
