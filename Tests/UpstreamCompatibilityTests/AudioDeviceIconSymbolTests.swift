// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/AudioDeviceIconSymbolTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Pure symbol selection moved from Core Audio ID extension to App DeviceIconSymbol; inputs/expectations preserved.

// FineTuneTests/AudioDeviceIconSymbolTests.swift

import AudioToolbox
import Testing

@testable import FineTune

@Suite("DeviceIconSymbol.iconSymbol(forName:transport:)")
struct AudioDeviceIconSymbolTests {

  @Test(
    "Device name maps to the expected SF Symbol",
    arguments: [
      ("AirPods Pro", "airpodspro"),
      ("Someone's AirPods Max", "airpodsmax"),
      ("AirPods", "airpods.gen3"),
      ("HomePod mini", "homepodmini"),
      ("Living Room HomePod", "homepod"),
      ("Apple TV 4K", "appletv"),
      ("Beats Studio Pro", "beats.headphones"),
      ("Mac Studio Speakers", "macstudio.fill"),
      ("Mac mini", "macmini.fill"),
      ("MacBook Pro Speakers", "macbook"),
      ("iMac", "desktopcomputer"),
      ("Studio Display", "display"),
      ("Pro Display XDR", "display"),
    ])
  func mapsKnownNames(name: String, expected: String) {
    #expect(DeviceIconSymbol.iconSymbol(forName: name, transport: .unknown) == expected)
  }

  // The cascade is ordered most-specific-first; a reorder would silently mis-map a
  // shipping device, so pin the precedences that actually overlap.
  @Test("More specific names win over their prefixes")
  func cascadeOrdering() {
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "AirPods Pro", transport: .unknown) == "airpodspro")
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "AirPods Max", transport: .unknown) == "airpodsmax")
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "HomePod mini", transport: .unknown) == "homepodmini")
  }

  @Test(
    "Unrecognised name falls back to the transport-type symbol",
    arguments: [
      (TransportType.builtIn, "hifispeaker"),
      (TransportType.bluetooth, "headphones"),
      (TransportType.airPlay, "airplayaudio"),
      (TransportType.hdmi, "tv"),
      (TransportType.unknown, "hifispeaker"),
    ])
  func unknownNameUsesTransport(transport: TransportType, expected: String) {
    #expect(
      DeviceIconSymbol.iconSymbol(forName: "Generic USB Audio", transport: transport) == expected)
  }
}
