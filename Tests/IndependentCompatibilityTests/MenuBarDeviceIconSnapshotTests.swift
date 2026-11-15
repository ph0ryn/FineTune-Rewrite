// Independently authored coverage for the observed snapshot boundary.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AudioToolbox
import Testing

@testable import FineTune

@Suite("MenuBarDeviceIconResolver — observed snapshot boundary")
struct MenuBarDeviceIconSnapshotTests {
  @Test("An available current output does not probe lower-priority devices or the HAL fallback")
  func currentOutputShortCircuitsOtherLookups() {
    let current = AudioDevice(
      id: 2, uid: "current", name: "AirPods Pro", icon: nil, supportsAutoEQ: true)
    let other = AudioDevice(id: 1, uid: "other", name: "Speakers", icon: nil, supportsAutoEQ: true)
    var availabilityChecks: [AudioDeviceID] = []
    var fallbackConsulted = false
    let symbol = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: ["other"], outputDevices: [other, current], defaultDeviceID: 2,
      isDeviceAvailable: { device in
        availabilityChecks.append(device.id)
        return true
      },
      uidForDefaultID: { _ in
        fallbackConsulted = true
        return nil
      },
      symbolForDevice: { _ in "airpodspro" },
      symbolForDefaultID: { _ in
        fallbackConsulted = true
        return "unused"
      }
    )
    #expect(symbol == "airpodspro")
    #expect(availabilityChecks == [2])
    #expect(!fallbackConsulted)
  }
}
