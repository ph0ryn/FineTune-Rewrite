// SPDX-License-Identifier: MIT

import AppKit
import AudioToolbox
import FineTuneDomain
import FineTunePlatform
import Testing

@testable import FineTune

private func makeIndependentDevice(
  id: UInt32,
  uid: String,
  name: String,
  transportType: TransportType = .unknown
) -> AudioDevice {
  AudioDevice(
    id: AudioDeviceID(id),
    uid: uid,
    name: name,
    icon: nil,
    supportsAutoEQ: false,
    transportType: transportType
  )
}

@Suite("Independent Presentation Compatibility")
@MainActor
struct IndependentPresentationCompatibilityTests {

  @Test("DeviceIconCatalog entries expose distinct ids and valid search vocabulary")
  func deviceIconCatalogVocabulary() {
    let entries = DeviceIconCatalog.allEntries
    #expect(!entries.isEmpty)
    #expect(Set(entries.map(\.id)).count == entries.count)

    let airpods = DeviceIconCatalog.matching("airpods")
    #expect(!airpods.isEmpty)
    #expect(airpods.contains { $0.symbol.contains("airpods") })

    let suggested = DeviceIconCatalog.suggested(forName: "Sony WH-1000XM5", transport: .bluetooth)
    #expect(!suggested.isEmpty)
    #expect(suggested.count <= 8)
  }

  @Test("MenuBarDeviceIconResolver skips unavailable devices and respects non-empty priority")
  func menuBarDeviceIconSnapshot() {
    let devA = makeIndependentDevice(id: 10, uid: "a", name: "Speakers")
    let devB = makeIndependentDevice(id: 20, uid: "b", name: "AirPods Pro")

    let symbol = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: ["a", "b"],
      outputDevices: [devA, devB],
      defaultDeviceID: devA.id,
      isSymbolResolvable: { _ in true },
      isDeviceAvailable: { $0.uid != "a" },
      symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol }
    )
    #expect(symbol == "airpodspro")
  }

  @Test(
    "DeviceDetailSheet automatic tier badges and accessibility labels match each VolumeControlTier")
  func deviceDetailToggleTierBadges() {
    #expect(!DeviceDetailSheet.automaticTierBadge(.hardware).isEmpty)
    #expect(!DeviceDetailSheet.automaticTierBadge(.ddc).isEmpty)
    #expect(!DeviceDetailSheet.automaticTierBadge(.software).isEmpty)
    #expect(!DeviceDetailSheet.automaticTierAccessibilityLabel(.hardware).isEmpty)
    #expect(!DeviceDetailSheet.automaticTierAccessibilityLabel(.ddc).isEmpty)
    #expect(!DeviceDetailSheet.automaticTierAccessibilityLabel(.software).isEmpty)
  }
}
