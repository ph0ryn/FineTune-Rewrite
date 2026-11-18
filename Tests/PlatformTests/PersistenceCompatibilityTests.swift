// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune at upstream revision 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Consolidated persistence, settings schema migration, priority merge, and preset CRUD compatibility tests.

import FineTuneControl
import FineTuneDomain
import Foundation
import KeyboardShortcuts
import Testing

@testable import FineTunePlatform

@MainActor
private final class CompatLaunchAtLoginService: LaunchAtLoginService {
  private(set) var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
private func makeTempSettingsManager() throws -> (SettingsManager, URL) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("FineTuneCompatPersistence-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let manager = SettingsManager(directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
  return (manager, dir)
}

// MARK: - Settings JSON Serialization & Normalization

@Suite("Compat: SettingsManager.Settings — JSON serialization")
@MainActor
struct UpstreamSettingsJSONTests {
  @Test("Default Settings encodes and decodes to equal value")
  func defaultRoundTrip() throws {
    let original = SettingsManager.Settings()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
    #expect(decoded.version == original.version)
    #expect(decoded.appVolumes == original.appVolumes)
    #expect(decoded.appMutes == original.appMutes)
    #expect(decoded.systemSoundsFollowsDefault == original.systemSoundsFollowsDefault)
  }

  @Test("Populated Settings round-trips all fields")
  func populatedRoundTrip() throws {
    var original = SettingsManager.Settings()
    original.appVolumes = ["com.test.app": 0.5]
    original.appMutes = ["com.test.app": true]
    original.appBoosts = ["com.test.app": 2.0]
    original.appDeviceRouting = ["com.test.app": "device-uid-123"]
    original.pinnedApps = Set(["com.test.app"])
    original.outputDevicePriority = ["uid-a", "uid-b", "uid-c"]
    original.ddcVolumes = ["monitor-1": 75]
    original.ddcMuteStates = ["monitor-1": false]
    original.autoEQPreampEnabled = false
    original.hiddenOutputDeviceUIDs = ["uid-hidden-out-1", "uid-hidden-out-2"]
    original.hiddenInputDeviceUIDs = ["uid-hidden-in-1"]
    original.deviceIconOverrides = ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"]

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)

    #expect(decoded.appVolumes == original.appVolumes)
    #expect(decoded.appMutes == original.appMutes)
    #expect(decoded.appBoosts == original.appBoosts)
    #expect(decoded.appDeviceRouting == original.appDeviceRouting)
    #expect(decoded.pinnedApps == original.pinnedApps)
    #expect(decoded.outputDevicePriority == original.outputDevicePriority)
    #expect(decoded.ddcVolumes == original.ddcVolumes)
    #expect(decoded.ddcMuteStates == original.ddcMuteStates)
    #expect(decoded.autoEQPreampEnabled == false)
    #expect(decoded.hiddenOutputDeviceUIDs == original.hiddenOutputDeviceUIDs)
    #expect(decoded.hiddenInputDeviceUIDs == original.hiddenInputDeviceUIDs)
    #expect(decoded.deviceIconOverrides == original.deviceIconOverrides)
  }

  @Test("Decoding empty JSON produces valid defaults")
  func emptyJSONDefaults() throws {
    let data = Data("{}".utf8)
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
    #expect(decoded.version == 9)
    #expect(decoded.appVolumes.isEmpty)
    #expect(decoded.appMutes.isEmpty)
    #expect(decoded.systemSoundsFollowsDefault == true)
    #expect(decoded.autoEQPreampEnabled == true)
    #expect(decoded.hiddenOutputDeviceUIDs.isEmpty)
    #expect(decoded.hiddenInputDeviceUIDs.isEmpty)
    #expect(decoded.deviceIconOverrides.isEmpty)
  }

  @Test("Decoding with extra unknown keys is tolerated")
  func unknownKeysIgnored() throws {
    let json = """
      {"version": 9, "unknownField": "hello", "anotherNew": 42}
      """
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.version == 9)
  }

  @Test("Volume values above 1.0 are clamped to 1.0 on decode")
  func volumeClampedAboveOne() throws {
    let json = """
      {"appVolumes": {"com.test.app": 1.5, "com.other.app": 0.8}}
      """
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.appVolumes["com.test.app"] == 1.0)
    #expect(decoded.appVolumes["com.other.app"] == 0.8)
  }

  @Test("Negative volume values are filtered out on decode")
  func negativeVolumesFiltered() throws {
    let json = """
      {"appVolumes": {"com.test.app": -0.5, "com.good.app": 0.7}}
      """
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.appVolumes["com.test.app"] == nil)
    #expect(decoded.appVolumes["com.good.app"] == 0.7)
  }

  @Test("Non-finite volume values cannot be encoded to JSON")
  func nonFiniteVolumesCannotEncode() {
    var settings = SettingsManager.Settings()
    settings.appVolumes["inf_app"] = Float.infinity
    #expect(throws: EncodingError.self) {
      _ = try JSONEncoder().encode(settings)
    }
  }

  @Test("Invalid defaultNewAppVolume is reset to 1.0 on decode")
  func invalidDefaultVolumeReset() throws {
    let json = """
      {"appSettings": {"launchAtLogin": false, "menuBarIconStyle": "Default", "defaultNewAppVolume": -5.0, "lockInputDevice": true, "showDeviceDisconnectAlerts": true}}
      """
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.appSettings.defaultNewAppVolume == 1.0)
  }

  @Test(
    "SettingsManager.Settings round-trip preserves appearance, hudStyle, and loudnessEqualizationEnabled"
  )
  func settingsManagerFieldRoundTrips() throws {
    var settings = SettingsManager.Settings()
    settings.appSettings.appearance = .light
    settings.appSettings.hudStyle = .classic
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
    #expect(decoded.appSettings.appearance == .light)
    #expect(decoded.appSettings.hudStyle == .classic)

    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    var appSettings = manager.appSettings
    appSettings.loudnessEqualizationEnabled = true
    manager.updateAppSettings(appSettings)
    #expect(manager.appSettings.loudnessEqualizationEnabled == true)
  }
}

// MARK: - mergePriorityOrder

@Suite("Compat: SettingsManager — mergePriorityOrder algorithm")
@MainActor
struct UpstreamMergePriorityOrderTests {
  @Test("No disconnected devices: returns connectedOrder as-is")
  func noDisconnected() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "B", "C"], connectedOrder: ["C", "A", "B"])
    #expect(result == ["C", "A", "B"])
  }

  @Test("Disconnected device anchored between two connected devices")
  func disconnectedBetween() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "D", "B"], connectedOrder: ["A", "B"])
    #expect(result == ["A", "D", "B"])
  }

  @Test("Disconnected device at the beginning (no preceding connected device)")
  func disconnectedAtStart() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["D", "A", "B"], connectedOrder: ["A", "B"])
    #expect(result == ["D", "A", "B"])
  }

  @Test("Multiple disconnected devices with same anchor")
  func multipleDisconnectedSameAnchor() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "D1", "D2", "B"], connectedOrder: ["A", "B"])
    #expect(result == ["A", "D1", "D2", "B"])
  }

  @Test("All devices disconnected: returns disconnected in old order")
  func allDisconnected() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "B", "C"], connectedOrder: [])
    #expect(result == ["A", "B", "C"])
  }

  @Test("Empty old priority: returns connectedOrder")
  func emptyOldPriority() {
    let result = SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: ["X", "Y"])
    #expect(result == ["X", "Y"])
  }

  @Test("Both empty: returns empty")
  func bothEmpty() {
    #expect(SettingsManager.mergePriorityOrder(oldPriority: [], connectedOrder: []).isEmpty)
  }

  @Test("Reordering connected devices preserves disconnected anchors")
  func reorderPreservesAnchors() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "D1", "B", "D2", "C"], connectedOrder: ["C", "A", "B"])
    #expect(result == ["C", "A", "D1", "B", "D2"])
  }

  @Test("Disconnected device at end (anchored to last connected)")
  func disconnectedAtEnd() {
    let result = SettingsManager.mergePriorityOrder(
      oldPriority: ["A", "B", "D"], connectedOrder: ["A", "B"])
    #expect(result == ["A", "B", "D"])
  }
}

// MARK: - Hidden Devices & Icon Overrides

@Suite("Compat: SettingsManager — hidden device UIDs")
@MainActor
struct UpstreamSettingsManagerHiddenDevicesTests {
  @Test("hideOutputDevice / unhideOutputDevice / isOutputDeviceHidden round-trip")
  func outputHideUnhideParity() throws {
    let (m, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let uid = "uid-output-1"

    #expect(m.isOutputDeviceHidden(uid) == false)
    m.hideOutputDevice(uid: uid)
    #expect(m.isOutputDeviceHidden(uid) == true)
    #expect(m.hiddenOutputDeviceUIDs.contains(uid))
    m.unhideOutputDevice(uid: uid)
    #expect(m.isOutputDeviceHidden(uid) == false)
    #expect(m.hiddenOutputDeviceUIDs.contains(uid) == false)
  }

  @Test("hideInputDevice / unhideInputDevice / isInputDeviceHidden round-trip")
  func inputHideUnhideParity() throws {
    let (m, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let uid = "uid-input-1"

    #expect(m.isInputDeviceHidden(uid) == false)
    m.hideInputDevice(uid: uid)
    #expect(m.isInputDeviceHidden(uid) == true)
    m.unhideInputDevice(uid: uid)
    #expect(m.isInputDeviceHidden(uid) == false)
  }

  @Test("toggleOutputDeviceHidden flips based on persisted state")
  func toggleOutputFlipsFromPersisted() throws {
    let (m, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let uid = "uid-output-2"

    m.toggleOutputDeviceHidden(uid: uid)
    #expect(m.isOutputDeviceHidden(uid) == true)
    m.toggleOutputDeviceHidden(uid: uid)
    #expect(m.isOutputDeviceHidden(uid) == false)
  }

  @Test("toggleInputDeviceHidden flips based on persisted state")
  func toggleInputFlipsFromPersisted() throws {
    let (m, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let uid = "uid-input-2"

    m.toggleInputDeviceHidden(uid: uid)
    #expect(m.isInputDeviceHidden(uid) == true)
    m.toggleInputDeviceHidden(uid: uid)
    #expect(m.isInputDeviceHidden(uid) == false)
  }

  @Test("Hidden output and input sets are independent")
  func outputAndInputSetsIndependent() throws {
    let (m, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    m.hideOutputDevice(uid: "shared-uid")
    #expect(m.isOutputDeviceHidden("shared-uid") == true)
    #expect(m.isInputDeviceHidden("shared-uid") == false)
  }
}

@Suite("Compat: SettingsManager — deviceIconOverrides API")
@MainActor
struct UpstreamDeviceIconOverrideTests {
  @Test("get/set round-trip for a single UID")
  func setAndGet() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)

    manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
    #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")

    manager.setDeviceIconOverride(for: "uid-a", to: "gamecontroller.fill")
    #expect(manager.getDeviceIconOverride(for: "uid-a") == "gamecontroller.fill")
  }

  @Test("Passing nil clears the override")
  func clearOverride() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
    manager.setDeviceIconOverride(for: "uid-a", to: nil)
    #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
  }

  @Test("Overrides for different UIDs are independent")
  func independentPerUID() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
    manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")
    #expect(manager.getDeviceIconOverride(for: "uid-a") == "airpodsmax")
    #expect(manager.getDeviceIconOverride(for: "uid-b") == "gamecontroller.fill")
    #expect(manager.deviceIconOverrides == ["uid-a": "airpodsmax", "uid-b": "gamecontroller.fill"])
  }

  @Test("resetAllSettings clears all overrides")
  func resetClearsOverrides() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceIconOverride(for: "uid-a", to: "airpodsmax")
    manager.setDeviceIconOverride(for: "uid-b", to: "gamecontroller.fill")
    manager.resetAllSettings()
    #expect(manager.getDeviceIconOverride(for: "uid-a") == nil)
    #expect(manager.getDeviceIconOverride(for: "uid-b") == nil)
    #expect(manager.deviceIconOverrides.isEmpty)
  }
}

// MARK: - DeviceVolumeTier Overrides, v10→v11 Migration, and Silence Floor

@Suite("Compat: SettingsManager — deviceVolumeTierOverride, migration, and floor")
@MainActor
struct UpstreamDeviceVolumeTierPersistenceTests {
  private let v10JsonWithLegacyKey = #"""
    {
      "version": 10,
      "appVolumes": {},
      "appSettings": {
        "softwareDeviceVolumeEnabled": true,
        "defaultNewAppVolume": 1.0,
        "launchAtLogin": false,
        "menuBarIconStyle": "Default",
        "lockInputDevice": true,
        "showDeviceDisconnectAlerts": true,
        "loudnessCompensationEnabled": false,
        "loudnessEqualizationEnabled": false
      }
    }
    """#

  @Test("get/set round-trip for a single UID")
  func setAndGet() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .software)
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: .hardware)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .hardware)
  }

  @Test("Passing nil clears the override")
  func clearOverride() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: nil)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)
  }

  @Test("Overrides for different UIDs are independent")
  func independentPerUID() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
    manager.setDeviceVolumeTierOverride(for: "uid-b", to: .hardware)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == .software)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-b") == .hardware)
  }

  @Test("resetAllSettings clears all overrides")
  func resetClearsOverrides() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.setDeviceVolumeTierOverride(for: "uid-a", to: .software)
    manager.setDeviceVolumeTierOverride(for: "uid-b", to: .hardware)
    manager.resetAllSettings()
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-a") == nil)
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-b") == nil)
  }

  @Test("Setting an override to .software persists override and software mute sync")
  func overrideToSoftwareInstalls() throws {
    let (settings, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    settings.setDeviceVolumeTierOverride(for: "uid-y", to: .software)
    #expect(settings.getDeviceVolumeTierOverride(for: "uid-y") == .software)
    settings.setSoftwareDeviceMuteState(for: "uid-y", to: true)
    #expect(settings.getSoftwareDeviceMuteState(for: "uid-y") == true)
  }

  @Test("Clearing the override via detail sheet revert restores auto-detection")
  func overrideRevertClears() throws {
    let (settings, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    settings.setDeviceVolumeTierOverride(for: "uid-y", to: .software)
    settings.setDeviceVolumeTierOverride(for: "uid-y", to: nil)
    #expect(settings.getDeviceVolumeTierOverride(for: "uid-y") == nil)
  }

  @Test("Decoding a v10 settings.json silently discards softwareDeviceVolumeEnabled")
  func decodeV10TolerantOfRemovedKey() throws {
    let decoded = try JSONDecoder().decode(
      SettingsManager.Settings.self, from: Data(v10JsonWithLegacyKey.utf8))
    #expect(decoded.version == 10)
    #expect(decoded.deviceVolumeTierOverride.isEmpty == true)
    #expect(decoded.appSettings.lockInputDevice == true)
    #expect(decoded.appSettings.showDeviceDisconnectAlerts == true)
    #expect(decoded.softwareDeviceVolumes.isEmpty)
    #expect(decoded.softwareDeviceMuteStates.isEmpty)
    #expect(decoded.softwareDeviceSavedVolumes.isEmpty)
  }

  @Test("Re-encode after v10 decode bumps to v12 on a fresh Settings instance")
  func defaultSettingsVersionIsTwelve() {
    let fresh = SettingsManager.Settings()
    #expect(fresh.version == 12)
    #expect(fresh.deviceVolumeTierOverride.isEmpty)
  }

  @Test("SettingsManager loads from disk without throwing for a v10 file on-disk")
  func loadV10FromDisk() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTuneCompatV10-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(v10JsonWithLegacyKey.utf8).write(
      to: dir.appendingPathComponent("settings.json"), options: .atomic)
    let manager = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    #expect(manager.getDeviceVolumeTierOverride(for: "uid-any") == nil)
  }

  @Test("v11 fixture decodes with deviceVolumeTierOverride and software-volume dicts populated")
  func decodeV11Fixture() throws {
    let json = #"""
      {
        "version": 11,
        "appVolumes": {},
        "appSettings": {
          "defaultNewAppVolume": 1.0,
          "launchAtLogin": false,
          "menuBarIconStyle": "Default",
          "lockInputDevice": true,
          "showDeviceDisconnectAlerts": true,
          "loudnessCompensationEnabled": false,
          "loudnessEqualizationEnabled": false,
          "mediaKeyControlEnabled": true,
          "hudStyle": "tahoe"
        },
        "deviceVolumeTierOverride": {
          "uid-usb-interface": "software",
          "uid-external-display": "ddc"
        },
        "softwareDeviceVolumes": {
          "uid-usb-interface": 0.6
        },
        "softwareDeviceMuteStates": {
          "uid-usb-interface": false
        },
        "softwareDeviceSavedVolumes": {
          "uid-usb-interface": 0.6
        }
      }
      """#
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.version == 11)
    #expect(decoded.deviceVolumeTierOverride["uid-usb-interface"] == .software)
    #expect(decoded.deviceVolumeTierOverride["uid-external-display"] == .ddc)
    #expect(decoded.softwareDeviceVolumes["uid-usb-interface"] == 0.6)
    #expect(decoded.softwareDeviceMuteStates["uid-usb-interface"] == false)
    #expect(decoded.softwareDeviceSavedVolumes["uid-usb-interface"] == 0.6)
    #expect(decoded.appSettings.mediaKeyControlEnabled == true)
  }

  @Test("New deviceVolumeTierOverride field round-trips through JSON")
  func overrideRoundTrip() throws {
    var original = SettingsManager.Settings()
    original.deviceVolumeTierOverride = [
      "uid-hw": .hardware,
      "uid-ddc": .ddc,
      "uid-sw": .software,
    ]
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
    #expect(decoded.deviceVolumeTierOverride == original.deviceVolumeTierOverride)
  }

  @Test("Default Settings has empty deviceVolumeTierOverride")
  func defaultEmpty() {
    #expect(SettingsManager.Settings().deviceVolumeTierOverride.isEmpty)
  }
}

@Suite("Compat: DeviceVolumePolicy.storedVolume — tier-aware silence floor")
struct UpstreamDeviceVolumeStoredVolumeTests {
  @Test("Hardware/DDC floor sub-1% scalar to true silence")
  func hardwareDdcFloorBelowOnePercent() {
    #expect(DeviceVolumePolicy.storedVolume(0.005, tier: .hardware) == 0)
    #expect(DeviceVolumePolicy.storedVolume(0.009, tier: .ddc) == 0)
    #expect(DeviceVolumePolicy.storedVolume(0.0039, tier: .hardware) == 0)
  }

  @Test("Hardware/DDC keep values at or above the 1% floor")
  func hardwareDdcKeepAboveFloor() {
    #expect(DeviceVolumePolicy.storedVolume(0.01, tier: .hardware) == 0.01)
    #expect(DeviceVolumePolicy.storedVolume(0.5, tier: .ddc) == 0.5)
  }

  @Test("Software tier is never floored — preserves sub-1% gain (issue #295)")
  func softwareNeverFloored() {
    #expect(DeviceVolumePolicy.storedVolume(0.0039, tier: .software) == 0.0039)
    #expect(DeviceVolumePolicy.storedVolume(0.0001, tier: .software) == 0.0001)
    #expect(DeviceVolumePolicy.storedVolume(0.5, tier: .software) == 0.5)
    #expect(DeviceVolumePolicy.storedVolume(0.0, tier: .software) == 0.0)
  }

  @Test(
    "Software volume steps up out of silence instead of freezing at 0",
    arguments: [VolumeHotkeyStep.coarse, .normal, .fine, .extraFine])
  func softwareStepRecoversFromZero(step: VolumeHotkeyStep) {
    let tier = VolumeControlTier.software
    var stored: Float = 0
    let currentSlider = VolumeMapping.sliderFraction(forSystemGain: stored, tier: tier)
    let nextSlider = min(1.0, currentSlider + step.sliderDelta)
    let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
    stored = DeviceVolumePolicy.storedVolume(newVolume, tier: tier)
    #expect(stored > 0)
  }
}

// MARK: - UserEQPreset CRUD, Name Validation, and Persistence

@Suite("Compat: SettingsManager — User EQ Preset CRUD")
@MainActor
struct UpstreamUserEQPresetCRUDTests {
  @Test("createUserPreset returns preset with matching name and bandGains")
  func createReturnsPreset() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let gains: [Float] = [6, 3, 0, -3, -6, 0, 3, 6, 3, 0]
    let preset = manager.createUserPreset(
      name: "Bass Heavy", settings: EQSettings(bandGains: gains))
    #expect(preset.name == "Bass Heavy")
    #expect(preset.settings.bandGains == gains)
  }

  @Test("createUserPreset generates a unique UUID")
  func createGeneratesUniqueID() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "A", settings: EQSettings())
    let b = manager.createUserPreset(name: "B", settings: EQSettings())
    #expect(a.id != b.id)
  }

  @Test("createUserPreset with empty name falls back to Untitled")
  func createEmptyName() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "", settings: EQSettings())
    #expect(preset.name == "Untitled")
    let presets = manager.getUserPresets()
    #expect(presets.count == 1)
    #expect(presets[0].name == "Untitled")
  }

  @Test("createUserPreset auto-suffixes duplicate names Finder-style")
  func createDuplicateNames() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "Same Name", settings: EQSettings())
    let b = manager.createUserPreset(name: "Same Name", settings: EQSettings())
    #expect(a.id != b.id)
    #expect(a.name == "Same Name")
    #expect(b.name == "Same Name (2)")
    #expect(Set(manager.getUserPresets().map(\.name)) == ["Same Name", "Same Name (2)"])
  }

  @Test("getUserPresets returns empty array when no presets exist")
  func getPresetsEmpty() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(manager.getUserPresets().isEmpty)
  }

  @Test("getUserPresets returns presets sorted by createdAt descending (newest first)")
  func getPresetsSortedNewestFirst() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTuneCompatSort-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let fixture = #"""
      {
          "version": 12,
          "userEQPresets": [
              {
                  "id": "11111111-1111-4111-8111-111111111111",
                  "name": "Oldest",
                  "settings": {"bandGains": [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "isEnabled": true},
                  "createdAt": 1000000
              },
              {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "name": "Newest",
                  "settings": {"bandGains": [10, 9, 8, 7, 6, 5, 4, 3, 2, 1], "isEnabled": false},
                  "createdAt": 3000000
              },
              {
                  "id": "33333333-3333-4333-8333-333333333333",
                  "name": "Middle",
                  "settings": {"bandGains": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "isEnabled": true},
                  "createdAt": 2000000
              }
          ]
      }
      """#
    try Data(fixture.utf8).write(to: dir.appendingPathComponent("settings.json"), options: .atomic)

    let manager = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    #expect(manager.lastLoadError == nil)
    let presets = manager.getUserPresets()
    #expect(
      presets.map(\.id.uuidString) == [
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
        "11111111-1111-4111-8111-111111111111",
      ])
  }

  @Test("getUserPresets returns all created presets")
  func getPresetsReturnsAll() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<5 {
      manager.createUserPreset(name: "Preset \(i)", settings: EQSettings())
    }
    #expect(manager.getUserPresets().count == 5)
  }

  @Test("updateUserPreset renames an existing preset")
  func renameExisting() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Original", settings: EQSettings())
    manager.updateUserPreset(id: preset.id, name: "Renamed")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "Renamed")
  }

  @Test("updateUserPreset with nonexistent ID is a no-op (no crash)")
  func renameNonexistentID() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Keep", settings: EQSettings())
    manager.updateUserPreset(id: UUID(), name: "Ghost")
    let presets = manager.getUserPresets()
    #expect(presets.count == 1)
    #expect(presets[0].name == "Keep")
    #expect(presets[0].id == preset.id)
  }

  @Test("updateUserPreset preserves bandGains and other fields")
  func renamePreservesBandGains() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let gains: [Float] = [12, -12, 6, -6, 3, -3, 0, 1, -1, 5]
    let preset = manager.createUserPreset(name: "Before", settings: EQSettings(bandGains: gains))
    manager.updateUserPreset(id: preset.id, name: "After")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "After")
    #expect(found.settings.bandGains == gains)
    #expect(found.createdAt == preset.createdAt)
  }

  @Test("updateUserPreset with empty name is a no-op (keeps old name)")
  func renameToEmpty() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Had a Name", settings: EQSettings())
    manager.updateUserPreset(id: preset.id, name: "")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "Had a Name")
  }

  @Test("deleteUserPreset removes the preset by ID")
  func deleteExisting() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "ToDelete", settings: EQSettings())
    manager.deleteUserPreset(id: preset.id)
    #expect(manager.getUserPresets().isEmpty)
  }

  @Test("deleteUserPreset with nonexistent ID is a no-op (no crash)")
  func deleteNonexistentID() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Keep", settings: EQSettings())
    manager.deleteUserPreset(id: UUID())
    let presets = manager.getUserPresets()
    #expect(presets.count == 1)
    #expect(presets[0].id == preset.id)
  }

  @Test("deleteUserPreset only removes the targeted preset, not others")
  func deleteOnlyTarget() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "A", settings: EQSettings())
    let b = manager.createUserPreset(name: "B", settings: EQSettings())
    let c = manager.createUserPreset(name: "C", settings: EQSettings())
    manager.deleteUserPreset(id: b.id)
    let ids = Set(manager.getUserPresets().map(\.id))
    #expect(ids == [a.id, c.id])
  }

  @Test("Deleting all presets one by one leaves empty list")
  func deleteAllOneByOne() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let presets = (0..<3).map {
      manager.createUserPreset(name: "Preset \($0)", settings: EQSettings())
    }
    for preset in presets { manager.deleteUserPreset(id: preset.id) }
    #expect(manager.getUserPresets().isEmpty)
  }

  @Test("Double-deleting the same ID is a no-op on second call")
  func doubleDelete() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Once", settings: EQSettings())
    manager.deleteUserPreset(id: preset.id)
    manager.deleteUserPreset(id: preset.id)
    #expect(manager.getUserPresets().isEmpty)
  }

  @Test("Create after delete reuses no state from deleted preset")
  func createAfterDelete() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = manager.createUserPreset(
      name: "Old", settings: EQSettings(bandGains: [12, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    manager.deleteUserPreset(id: old.id)
    let new = manager.createUserPreset(
      name: "New", settings: EQSettings(bandGains: [-6, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    #expect(new.id != old.id)
    #expect(new.name == "New")
    #expect(new.settings.bandGains[0] == -6)
    #expect(manager.getUserPresets().count == 1)
  }
}

@Suite("Compat: SettingsManager — User EQ Preset Name Validation")
@MainActor
struct UpstreamUserEQPresetNameValidationTests {
  @Test("createUserPreset trims leading and trailing whitespace")
  func createTrimsWhitespace() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "  Padded Name  ", settings: EQSettings())
    #expect(preset.name == "Padded Name")
  }

  @Test("createUserPreset trims tabs and newlines")
  func createTrimsTabsAndNewlines() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "\t\nTabbed\n\t", settings: EQSettings())
    #expect(preset.name == "Tabbed")
  }

  @Test("createUserPreset with whitespace-only name falls back to Untitled")
  func createWhitespaceOnlyName() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "   ", settings: EQSettings())
    #expect(preset.name == "Untitled")
  }

  @Test("updateUserPreset trims whitespace on rename")
  func renameTrimsWhitespace() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Original", settings: EQSettings())
    manager.updateUserPreset(id: preset.id, name: "  Trimmed  ")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "Trimmed")
  }

  @Test("updateUserPreset with whitespace-only name is a no-op")
  func renameWhitespaceOnlyNoOp() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "Keep This", settings: EQSettings())
    manager.updateUserPreset(id: preset.id, name: "   \t\n  ")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "Keep This")
  }

  @Test("Duplicate names produce sequential suffixes: Name, Name (2), Name (3)")
  func finderDedupChain() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "Rock", settings: EQSettings())
    let b = manager.createUserPreset(name: "Rock", settings: EQSettings())
    let c = manager.createUserPreset(name: "Rock", settings: EQSettings())
    #expect(a.name == "Rock")
    #expect(b.name == "Rock (2)")
    #expect(c.name == "Rock (3)")
  }

  @Test("Dedup chain skips existing suffixed names to find next available")
  func dedupChainSkipsExisting() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.createUserPreset(name: "Jazz", settings: EQSettings())
    manager.createUserPreset(name: "Jazz (2)", settings: EQSettings())
    let third = manager.createUserPreset(name: "Jazz", settings: EQSettings())
    #expect(third.name == "Jazz (3)")
  }

  @Test("Multiple Untitled presets follow dedup chain")
  func multipleUntitledDedup() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "", settings: EQSettings())
    let b = manager.createUserPreset(name: "", settings: EQSettings())
    let c = manager.createUserPreset(name: "   ", settings: EQSettings())
    #expect(a.name == "Untitled")
    #expect(b.name == "Untitled (2)")
    #expect(c.name == "Untitled (3)")
  }

  @Test("Rename to own current name produces no suffix (excludeID)")
  func renameToSelfNoSuffix() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager.createUserPreset(name: "MyPreset", settings: EQSettings())
    manager.updateUserPreset(id: preset.id, name: "MyPreset")
    let found = try #require(manager.getUserPresets().first { $0.id == preset.id })
    #expect(found.name == "MyPreset")
  }

  @Test("Rename colliding with another preset auto-suffixes")
  func renameCollisionAutoSuffixes() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "Bass", settings: EQSettings())
    let b = manager.createUserPreset(name: "Treble", settings: EQSettings())
    manager.updateUserPreset(id: b.id, name: "Bass")
    #expect(manager.getUserPresets().first { $0.id == a.id }?.name == "Bass")
    #expect(manager.getUserPresets().first { $0.id == b.id }?.name == "Bass (2)")
  }

  @Test("Rename with trimmed result colliding gets suffixed")
  func renameTrimmedCollision() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    manager.createUserPreset(name: "Vocal", settings: EQSettings())
    let b = manager.createUserPreset(name: "Other", settings: EQSettings())
    manager.updateUserPreset(id: b.id, name: "  Vocal  ")
    #expect(manager.getUserPresets().first { $0.id == b.id }?.name == "Vocal (2)")
  }

  @Test("Dedup handles names that already contain parenthesized numbers")
  func dedupWithExistingParenNumbers() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = manager.createUserPreset(name: "Preset (2)", settings: EQSettings())
    let b = manager.createUserPreset(name: "Preset (2)", settings: EQSettings())
    #expect(a.name == "Preset (2)")
    #expect(b.name == "Preset (2) (2)")
  }

  @Test("Deleting a preset frees its name for reuse without suffix")
  func deleteFreesNameForReuse() throws {
    let (manager, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = manager.createUserPreset(name: "Ephemeral", settings: EQSettings())
    manager.deleteUserPreset(id: first.id)
    let reused = manager.createUserPreset(name: "Ephemeral", settings: EQSettings())
    #expect(reused.name == "Ephemeral")
  }
}

@Suite("Compat: SettingsManager — User EQ Preset Persistence & Version")
@MainActor
struct UpstreamUserEQPresetPersistenceTests {
  @Test("Created preset survives SettingsManager re-init from same directory")
  func persistenceRoundTrip() throws {
    let (manager1, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let gains: [Float] = [3, 6, 9, 6, 3, 0, -3, -6, -9, -6]
    let created = manager1.createUserPreset(
      name: "Persistent Preset", settings: EQSettings(bandGains: gains))
    manager1.flushSync()

    let manager2 = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    let presets = manager2.getUserPresets()
    #expect(presets.count == 1)
    let loaded = try #require(presets.first)
    #expect(loaded.id == created.id)
    #expect(loaded.name == "Persistent Preset")
    #expect(loaded.settings.bandGains == gains)
  }

  @Test("Multiple presets survive persistence round-trip")
  func multiplePresetsRoundTrip() throws {
    let (manager1, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = manager1.createUserPreset(
      name: "First", settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    let second = manager1.createUserPreset(
      name: "Second", settings: EQSettings(bandGains: [2, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    manager1.flushSync()

    let manager2 = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    let ids = Set(manager2.getUserPresets().map(\.id))
    #expect(ids == [first.id, second.id])
  }

  @Test("Deleted preset does not survive persistence round-trip")
  func deletePersistedRoundTrip() throws {
    let (manager1, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager1.createUserPreset(name: "Ephemeral", settings: EQSettings())
    manager1.deleteUserPreset(id: preset.id)
    manager1.flushSync()

    let manager2 = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    #expect(manager2.getUserPresets().isEmpty)
  }

  @Test("Renamed preset persists with new name")
  func renamePersistedRoundTrip() throws {
    let (manager1, dir) = try makeTempSettingsManager()
    defer { try? FileManager.default.removeItem(at: dir) }
    let preset = manager1.createUserPreset(name: "Before", settings: EQSettings())
    manager1.updateUserPreset(id: preset.id, name: "After")
    manager1.flushSync()

    let manager2 = SettingsManager(
      directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
    let loaded = try #require(manager2.getUserPresets().first { $0.id == preset.id })
    #expect(loaded.name == "After")
  }

  @Test("Default Settings().version is 12 and userEQPresets defaults to empty")
  func defaultVersionAndUserEQPresets() {
    let settings = SettingsManager.Settings()
    #expect(settings.version == 12)
    #expect(settings.userEQPresets.isEmpty)
  }

  @Test("Decoding JSON without userEQPresets key defaults to empty array")
  func decodeWithoutUserEQPresets() throws {
    let decoded = try JSONDecoder().decode(
      SettingsManager.Settings.self, from: Data(#"{"version": 10}"#.utf8))
    #expect(decoded.userEQPresets.isEmpty)
  }

  @Test("Decoding JSON with userEQPresets array preserves presets")
  func decodeWithUserEQPresets() throws {
    let json = """
      {
          "version": 10,
          "userEQPresets": [
              {
                  "id": "550E8400-E29B-41D4-A716-446655440000",
                  "name": "My Preset",
                  "settings": {"bandGains": [1,2,3,4,5,6,7,8,9,10], "isEnabled": true},
                  "createdAt": 1000000
              }
          ]
      }
      """
    let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
    #expect(decoded.userEQPresets.count == 1)
    #expect(decoded.userEQPresets[0].name == "My Preset")
    #expect(decoded.userEQPresets[0].settings.bandGains == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  }
}

// MARK: - Custom Shortcuts & ShortcutCodable

@Suite("Compat: AppSettings customShortcuts & ShortcutCodable")
@MainActor
struct UpstreamShortcutsPersistenceTests {
  @Test("round-trips a custom shortcut in AppSettings")
  func roundTripCustomShortcut() throws {
    var settings = AppSettings()
    settings.customShortcuts[ShortcutAction.togglePopup.rawValue] =
      ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.customShortcuts == settings.customShortcuts)
  }

  @Test("customShortcuts defaults to empty when missing from JSON")
  func defaultsEmpty() throws {
    let json = """
      { "defaultNewAppVolume": 1.0 }
      """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    #expect(decoded.customShortcuts.isEmpty)
  }

  @Test("ShortcutCodable round-trips through JSON")
  func shortcutCodableRoundTrip() throws {
    let original = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ShortcutCodable.self, from: data)
    #expect(decoded == original)
  }

  @Test("inverse of KeyboardShortcuts.Shortcut")
  func shortcutCodableInverse() {
    let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 9, carbonModifiers: 0x100)
    let codable = ShortcutCodable.from(shortcut)
    let recovered = codable.keyboardShortcut
    #expect(recovered.carbonKeyCode == shortcut.carbonKeyCode)
    #expect(recovered.carbonModifiers == shortcut.carbonModifiers)
  }
}
