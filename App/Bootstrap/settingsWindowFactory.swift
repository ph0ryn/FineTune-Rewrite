import AppKit
import SwiftUI

/// Builds the Settings window. The SwiftUI content must be hosted through an NSHostingView in
/// contentView: window contentViewController(NSHostingController) detaches the TabView bar from
/// the title bar and renders it as a plain strip below it.
@MainActor
enum SettingsWindowFactory {
  static func make<Content: View>(content: Content) -> NSWindow {
    let hosting = NSHostingView(rootView: content)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }
}
