// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/AudioEngineToggleMuteTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
import AppKit
import Foundation
// FineTuneTests/AudioEngineToggleMuteTests.swift
import Testing

@testable import FineTune

@Suite("AudioEngine.toggleMute")
@MainActor
struct AudioEngineToggleMuteTests {
  @Test("toggleMute flips an unmuted app to muted")
  func toggleUnmutedToMuted() {
    let (engine, app) = makeEngineWithApp(initiallyMuted: false)

    engine.toggleMute(for: app)

    #expect(engine.volumeState.getMute(for: app.id) == true)
  }

  @Test("toggleMute flips a muted app to unmuted")
  func toggleMutedToUnmuted() {
    let (engine, app) = makeEngineWithApp(initiallyMuted: true)

    engine.toggleMute(for: app)

    #expect(engine.volumeState.getMute(for: app.id) == false)
  }

  @Test("isAudibleNow returns false when no AudioApp matches the bundle ID")
  func isAudibleNowReturnsFalseForUnknownBundle() {
    let (engine, _) = makeEngineWithApp(initiallyMuted: false)
    #expect(engine.isAudibleNow(bundleID: "com.does.not.exist") == false)
  }

  @Test("isAudibleNow returns false when matched AudioApp has no processObjectIDs")
  func isAudibleNowReturnsFalseWhenNoProcessObjects() {
    let (engine, app) = makeEngineWithApp(initiallyMuted: false)
    #expect(engine.apps.contains { $0.bundleID == app.bundleID })
    #expect(app.processObjectIDs.isEmpty)
    #expect(engine.isAudibleNow(bundleID: app.bundleID ?? "") == false)
  }

  private func makeEngineWithApp(initiallyMuted: Bool) -> (AudioEngine, AudioApp) {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(
      directory: tempDir, launchAtLoginService: TestLaunchAtLoginService())
    let deviceMonitor = MockAudioDeviceMonitor()
    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    let processes = StubProcessMonitor()
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let engine = AudioEngine(
      controller: controller, settingsManager: settings,
      deviceObservations: deviceMonitor, processObservations: processes,
      deviceVolumeMonitor: mockVolume, readOutputFailure: { nil }
    )
    let app = AudioApp(
      id: 42424,
      processObjectIDs: [],
      name: "TestApp",
      icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
      bundleID: "com.test.toggleMute"
    )
    processes.activeApps = [app]
    engine.ingestObservations()
    engine.volumeState.setMute(
      for: app.id, to: initiallyMuted, identifier: app.persistenceIdentifier)
    return (engine, app)
  }
}
