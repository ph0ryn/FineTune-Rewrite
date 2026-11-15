// Independently authored coverage for the new App-to-window presentation boundary.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AppKit
import Testing

@testable import FineTune

@Suite("Appearance bridge — production host lifecycle")
@MainActor
struct AppearanceBridgeLifecycleTests {
  @Test("A pending appearance is applied when the host joins a window")
  func pendingAppearanceAppliedOnAttach() {
    _ = NSApplication.shared
    let host = WindowAppearanceBridge.AppearanceHostView(frame: .zero)
    host.appearanceOverride = AppearancePreference.dark.nsAppearance
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.contentView = host
    #expect(window.appearance?.name == .darkAqua)
  }

  @Test("Returning from an explicit override to System mirrors the application appearance")
  func systemReplacesExplicitWindowAppearance() {
    _ = NSApplication.shared
    let host = WindowAppearanceBridge.AppearanceHostView(frame: .zero)
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.contentView = host
    host.appearanceOverride = AppearancePreference.dark.nsAppearance
    host.synchronize()
    #expect(window.appearance?.name == .darkAqua)
    host.appearanceOverride = nil
    host.synchronize()
    #expect(window.appearance?.name == NSApplication.shared.effectiveAppearance.name)
  }
}
