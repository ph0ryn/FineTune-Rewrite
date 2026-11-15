// Independently authored coverage for the production picker rendering boundary.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AppKit
import SwiftUI
import Testing

@testable import FineTune

@Suite("DeviceIconPicker — production snapshot rendering")
@MainActor
struct DeviceIconPickerRenderingTests {
  @Test("The real picker lays out at the compatible width without emitting a selection on load")
  func snapshotRendersWithoutSelection() {
    _ = NSApplication.shared
    var selectionEmitted = false
    let picker = DeviceIconPicker(
      deviceName: "USB Audio", transport: .usb, automaticSymbol: "headphones",
      automaticIsSymbol: true, currentOverride: nil,
      onSelect: { _ in selectionEmitted = true })
    let host = NSHostingView(rootView: picker)
    let size = host.fittingSize
    #expect(size.width == 300)
    #expect(size.height > 300)
    #expect(!selectionEmitted)
  }
}
