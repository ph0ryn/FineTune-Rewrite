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

/// Keeps the hosted content transparent inside the actual glass surface, and publishes ideal size
/// changes to NSPopover. No screen-sized viewport or scrolling participates in popup sizing.
@MainActor
final class MenuBarPopupContentController: NSViewController {
  private let content: AnyView
  private let sizeDidChange: (NSSize) -> Void
  private lazy var hosting: NSHostingController<AnyView> = NSHostingController(
    rootView: AnyView(
      content.onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { [weak self] size in
        guard let self, self.isViewLoaded else { return }
        self.publishContentSize(size)
      }))

  init<Content: View>(content: Content, sizeDidChange: @escaping (NSSize) -> Void) {
    self.content = AnyView(content)
    self.sizeDidChange = sizeDidChange
    super.init(nibName: nil, bundle: nil)
    addChild(hosting)
    // The fixed-size SwiftUI content reports its own live layout, not a controller notification.
    hosting.sizingOptions = []
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    let content = hosting.view
    if #available(macOS 26, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = DesignTokens.Dimensions.cornerRadius + DesignTokens.Spacing.sm
      if #available(macOS 27, *) { glass.effectIsInteractive = false }
      // AppKit only guarantees glass z-order for contentView, not arbitrary subviews.
      glass.contentView = content
      view = glass
    } else {
      view = content
    }
    let size = hosting.sizeThatFits(
      in: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    view.setFrameSize(size)
    content.frame = view.bounds
    content.autoresizingMask = [.width, .height]
    publishContentSize(size)
  }

  private func publishContentSize(_ size: NSSize) {
    guard preferredContentSize != size else { return }
    preferredContentSize = size
    sizeDidChange(size)
  }
}

/// Concrete menu-bar presentation: visibility changes are shared with HUD guards.
@MainActor
final class MenuBarPresentation: NSObject, NSPopoverDelegate {
  let statusItem: NSStatusItem
  let popupController: MenuBarPopupController
  private let popover: NSPopover
  private let visibility: PopupVisibilityService
  private let willShow: () -> Void

  init<Content: View>(
    visibility: PopupVisibilityService, willShow: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.visibility = visibility
    self.willShow = willShow
    popover = Self.makePopover(content: content())
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    popupController = MenuBarPopupController()
    super.init()
    statusItem.button?.setAccessibilityTitle("FineTune")
    statusItem.button?.image = NSImage(
      systemSymbolName: "slider.horizontal.3", accessibilityDescription: "FineTune")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggle)
    popover.behavior = .transient
    popover.delegate = self
    popupController.attach(statusItem: statusItem) { [weak self] in self?.toggle() }
  }

  static func makePopover<Content: View>(content: Content) -> NSPopover {
    let popover = NSPopover()
    let controller = MenuBarPopupContentController(content: content) { [weak popover] size in
      popover?.contentSize = size
    }
    popover.contentViewController = controller
    // NSPopover does not load an arbitrary child controller or infer its later preferred size.
    controller.loadViewIfNeeded()
    popover.contentSize = controller.preferredContentSize
    return popover
  }

  @objc func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = statusItem.button {
      willShow()
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
