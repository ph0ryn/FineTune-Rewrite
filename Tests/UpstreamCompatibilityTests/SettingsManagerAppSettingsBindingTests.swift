// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/SettingsManagerAppSettingsBindingTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Original inputs/assertions preserved; default managers replaced by unique temporary directory + injected test login service, Foundation import and shared test-only helper added to avoid real settings/login effects.

// FineTuneTests/SettingsManagerAppSettingsBindingTests.swift
import Foundation
import Testing

@testable import FineTune

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {

  @Test("Direct assignment to appSettings persists the new value")
  func directAssignmentPersists() async {
    let manager = makeIsolatedBindingSettingsManager()
    var newSettings = manager.appSettings
    newSettings.defaultNewAppVolume = 0.42
    newSettings.lockInputDevice = true

    manager.appSettings = newSettings

    #expect(manager.appSettings.defaultNewAppVolume == 0.42)
    #expect(manager.appSettings.lockInputDevice == true)
  }

  @Test("Direct assignment forwards launch-at-login change to LaunchAtLoginService")
  func directAssignmentForwardsLaunchAtLogin() async {
    let manager = makeIsolatedBindingSettingsManager()
    var newSettings = manager.appSettings
    let original = newSettings.launchAtLogin
    newSettings.launchAtLogin = !original

    manager.appSettings = newSettings

    // Behavioral assertion: the setter ran updateAppSettings's full side-effect path.
    // We verify by reading back the persisted toggle — the side-effect plumbing
    // is covered by existing updateAppSettings tests, so we only need to confirm
    // the new setter doesn't bypass it.
    #expect(manager.appSettings.launchAtLogin == !original)
  }

  @Test("Direct assignment is equivalent to updateAppSettings for the same input")
  func directAssignmentEquivalentToUpdate() async {
    let managerA = makeIsolatedBindingSettingsManager()
    let managerB = makeIsolatedBindingSettingsManager()

    var modified = managerA.appSettings
    modified.defaultNewAppVolume = 0.7
    modified.mediaKeyControlEnabled = true
    modified.showDeviceDisconnectAlerts = false

    managerA.appSettings = modified
    managerB.updateAppSettings(modified)

    #expect(managerA.appSettings == managerB.appSettings)
  }
}

// Test-only ServiceManagement boundary. Never registers the real app for login.
@MainActor
final class TestLaunchAtLoginService: LaunchAtLoginService {
  private(set) var isEnabled = false
  private(set) var requests: [Bool] = []

  func setEnabled(_ enabled: Bool) throws {
    requests.append(enabled)
    isEnabled = enabled
  }
}

@MainActor
private func makeIsolatedBindingSettingsManager() -> SettingsManager {
  SettingsManager(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
    launchAtLoginService: TestLaunchAtLoginService()
  )
}
