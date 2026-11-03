import AppKit
import SwiftUI

@MainActor
protocol MenuBarPopupControlling: AnyObject {
  func toggle()
}

/// App-owned status items can be injected directly; discovery also supports externally created items.
@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
  private let accessibilityTitle: String
  private let eventPoster: (NSEvent) -> Void
  private weak var ownedStatusItem: NSStatusItem?
  private var toggleOwnedPopup: (() -> Void)?

  init(
    accessibilityTitle: String = "FineTune",
    eventPoster: @escaping (NSEvent) -> Void = { event in
      let application = NSApplication.shared
      if !application.isActive { application.activate(ignoringOtherApps: true) }
      application.postEvent(event, atStart: false)
    }
  ) {
    self.accessibilityTitle = accessibilityTitle
    self.eventPoster = eventPoster
  }

  func attach(statusItem: NSStatusItem, toggle: @escaping () -> Void) {
    ownedStatusItem = statusItem
    toggleOwnedPopup = toggle
  }

  func findStatusItem() -> NSStatusItem? {
    if let ownedStatusItem { return ownedStatusItem }
    return NSApplication.shared.windows.lazy
      .filter { $0.className.contains("NSStatusBarWindow") }
      .compactMap { window -> NSStatusItem? in
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
      }
      .first { item in
        let expectedClass =
          if #available(macOS 26, *) { "NSSceneStatusItem" } else { "NSStatusItem" }
        return item.className == expectedClass
          && item.button?.accessibilityTitle() == accessibilityTitle
      }
  }

  func toggle() {
    if ownedStatusItem != nil, let toggleOwnedPopup {
      toggleOwnedPopup()
      return
    }
    guard let button = findStatusItem()?.button, let window = button.window else { return }
    // Externally created status items own their event handling; do not invoke private actions synchronously.
    guard
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: button.bounds.midX, y: button.bounds.midY),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      )
    else { return }
    eventPoster(event)
  }
}

/// Concrete menu-bar presentation: visibility changes are shared with HUD guards.
@MainActor
final class MenuBarPresentation: NSObject, NSPopoverDelegate {
  let statusItem: NSStatusItem
  let popupController: MenuBarPopupController
  private let popover = NSPopover()
  private let visibility: PopupVisibilityService

  init<Content: View>(visibility: PopupVisibilityService, @ViewBuilder content: () -> Content) {
    self.visibility = visibility
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    popupController = MenuBarPopupController()
    super.init()
    statusItem.button?.setAccessibilityTitle("FineTune")
    statusItem.button?.image = NSImage(
      systemSymbolName: "slider.horizontal.3", accessibilityDescription: "FineTune")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggle)
    popover.contentViewController = NSHostingController(rootView: content())
    popover.behavior = .transient
    popover.delegate = self
    popupController.attach(statusItem: statusItem) { [weak self] in self?.toggle() }
  }

  @objc func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem.button {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    visibility.isVisible = popover.isShown
  }

  func popoverDidClose(_ notification: Notification) { visibility.isVisible = false }

  func shutdown() {
    popover.close()
    visibility.isVisible = false
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}
