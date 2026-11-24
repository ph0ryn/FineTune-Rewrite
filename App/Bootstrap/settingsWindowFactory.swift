import AppKit
import SwiftUI

/// Hosts SwiftUI directly in the window content so the settings tab row stays in normal content
/// below the title bar instead of being clipped by title-bar layout.
@MainActor
enum SettingsWindowFactory {
  static func make<Content: View>(content: Content) -> NSWindow {
    let hosting = NSHostingView(rootView: content)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.contentView = hosting
    window.backgroundColor = .windowBackgroundColor
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }
}
