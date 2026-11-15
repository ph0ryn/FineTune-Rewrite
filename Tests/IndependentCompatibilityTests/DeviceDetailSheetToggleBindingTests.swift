// Independently authored coverage for the actual Toggle binding.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AudioToolbox
import SwiftUI
import Testing

@testable import FineTune

@Suite("DeviceDetailSheet — binary software-volume toggle (AC #1–#5)")
@MainActor
struct DeviceDetailSheetToggleTests {
  private static let testDevice = AudioDevice(
    id: 42,
    uid: "uid-test",
    name: "Test Device",
    icon: nil,
    supportsAutoEQ: false
  )

  @Test("Rewrite: the rendered toggle binding emits and clears the software override")
  func actualToggleBinding() {
    var writes: [VolumeControlTier?] = []
    let sheet = DeviceDetailSheet(
      device: Self.testDevice,
      transportType: .builtIn,
      autoDetectedTier: .hardware,
      currentOverride: nil,
      onOverrideChange: { writes.append($0) },
      onDismiss: {}
    )
    #expect(sheet.useSoftwareBinding.wrappedValue == false)
    sheet.useSoftwareBinding.wrappedValue = true
    sheet.useSoftwareBinding.wrappedValue = false
    #expect(writes == [.software, nil])

    let overridden = DeviceDetailSheet(
      device: Self.testDevice,
      transportType: .builtIn,
      autoDetectedTier: .ddc,
      currentOverride: .software,
      onOverrideChange: { _ in },
      onDismiss: {}
    )
    #expect(overridden.useSoftwareBinding.wrappedValue)
  }
}
