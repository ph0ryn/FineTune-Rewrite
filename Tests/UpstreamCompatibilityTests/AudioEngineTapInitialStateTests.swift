// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/AudioEngineTapInitialStateTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// FineTuneTests/AudioEngineTapInitialStateTests.swift
// The original first-sound guarantees now exercise the actual shared Control owner and Prepared route port.

import AppKit
import AudioToolbox
import Foundation
import Testing

@testable import FineTune

/// Records external runtime commands, not a second implementation of desired state or DSP.
@MainActor
final class RecordingPreparedAudioRoute: PreparedAudioRoute {
  enum Event: Equatable {
    case commit(AudioOutputState)
    case startMuted(AudioOutputState)
    case update(AudioOutputState)
    case levels(AudioOutputLevels)
    case cancel
    case retire
  }
  let key: AudioRouteKey
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  private(set) var events: [Event] = []
  let activationError: AudioRouteFailure?
  private(set) var retired = false
  private let retirementSignals: AsyncStream<Void>
  private let retirementSignal: AsyncStream<Void>.Continuation

  init(key: AudioRouteKey, activationError: AudioRouteFailure? = nil) {
    self.key = key
    self.activationError = activationError
    let retirement = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    retirementSignals = retirement.stream
    retirementSignal = retirement.continuation
  }
  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append(.startMuted(state))
    if let activationError { throw activationError }
    return AudioRouteObservation(key: key, phase: .armed, acceptedRevision: state.revision)
  }
  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append(.commit(state))
    if let activationError { throw activationError }
    return AudioRouteObservation(key: key, phase: .committed, acceptedRevision: state.revision)
  }
  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append(.update(state))
    return AudioRouteObservation(key: key, phase: .accepted, acceptedRevision: state.revision)
  }
  func requestLevels(_ levels: AudioOutputLevels) { events.append(.levels(levels)) }
  func cancel() { events.append(.cancel) }
  func retire() async -> AudioRetirementResult {
    events.append(.retire)
    retired = true
    retirementSignal.yield(())
    return .retired
  }
  /// Buffered retire signal with a 30-second failure deadline and cancellation-safe stream cleanup.
  func waitUntilRetired() async throws {
    let signals = retirementSignals
    let signal = retirementSignal
    let deadline = ContinuousClock.now + .seconds(30)
    await withTaskCancellationHandler {
      await withTaskGroup(of: RetirementWaitResult.self) { group in
        group.addTask {
          var iterator = signals.makeAsyncIterator()
          return await iterator.next() == nil ? .streamFinished : .retired
        }
        group.addTask {
          do {
            try await Task.sleep(until: deadline, clock: .continuous)
            return .deadlineExpired
          } catch {
            return .cancelled
          }
        }
        var retiredObserved = false
        var reportedFailure = false
        for await result in group {
          switch result {
          case .retired:
            retiredObserved = true
            group.cancelAll()
          case .deadlineExpired:
            if !retiredObserved && !reportedFailure {
              reportedFailure = true
              Issue.record("Prepared route did not retire within 30 seconds")
              signal.finish()
            }
            group.cancelAll()
          case .streamFinished:
            if !retiredObserved && !reportedFailure && !Task.isCancelled {
              reportedFailure = true
              Issue.record("Prepared route retirement stream ended before retirement")
            }
            signal.finish()
            group.cancelAll()
          case .cancelled:
            if Task.isCancelled {
              signal.finish()
              group.cancelAll()
            }
          }
        }
      }
    } onCancel: {
      signal.finish()
    }
    try Task.checkCancellation()
    signal.finish()
  }

  private enum RetirementWaitResult: Sendable {
    case retired
    case streamFinished
    case deadlineExpired
    case cancelled
  }
}

@MainActor
final class RecordingAudioRoutingRuntime: AudioRoutingRuntime {
  private(set) var cleanupRetryRequests = 0
  func requestCleanupRetry() { cleanupRetryRequests += 1 }
  private(set) var requests: [AudioRouteRequest] = []
  private(set) var routes: [RecordingPreparedAudioRoute] = []
  var activationError: AudioRouteFailure?
  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    requests.append(request)
    let route = RecordingPreparedAudioRoute(key: request.key, activationError: activationError)
    routes.append(route)
    return route
  }
}

@MainActor
final class StubProcessMonitor: AudioProcessObservationProviding {
  var activeApps: [AudioApp] = []
  var onAppsChanged: (([AudioApp]) -> Void)?
  var onObservationChanged: (() -> Void)?
  var observation: AudioProcessObservationSnapshot {
    AudioProcessObservationSnapshot(activeApps: activeApps, health: .healthy, revision: 1)
  }
  func start() {}
  func stop() {}
}

@MainActor
private struct Fixture {
  let engine: AudioEngine
  let settings: SettingsManager
  let app: AudioApp
  let device: AudioDevice
  let runtime: RecordingAudioRoutingRuntime
  func activate() async {
    engine.setDevice(for: app, deviceUID: device.uid)
    engine.controller.perform(.requestCaptureStart)
    await engine.controller.waitForCurrentWork()
  }
  var lastTap: RecordingPreparedAudioRoute? { runtime.routes.last }
}

@MainActor
private func makeFixture(supportsAutoEQ: Bool = true, deviceVolume: Float = 0.75) -> Fixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let settings = SettingsManager(
    directory: directory, launchAtLoginService: TestLaunchAtLoginService())
  let devices = MockAudioDeviceMonitor()
  let device = AudioDevice(
    id: 99, uid: "uid-test", name: "Test Output", icon: nil,
    supportsAutoEQ: supportsAutoEQ, bindingRevision: 1)
  devices.addOutputDevice(device)
  let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
  volume.defaultDeviceUID = device.uid
  volume.volumes[device.id] = deviceVolume
  volume.muteStates[device.id] = false
  let app = AudioApp(
    id: 12345, processObjectIDs: [], name: "TestApp", icon: NSImage(),
    bundleID: "com.test.tapinitial", processRevision: 1)
  let processes = StubProcessMonitor()
  processes.activeApps = [app]
  let runtime = RecordingAudioRoutingRuntime()
  let cache = AutoEQProfileCache()
  let controller = AudioController(
    settings: settings, runtime: runtime,
    profileLookup: { cache.profile(for: $0) }, readDefaultRoutingDecision: { .followObserved })
  let engine = AudioEngine(
    controller: controller, settingsManager: settings,
    deviceObservations: devices, processObservations: processes,
    deviceVolumeMonitor: volume, readOutputFailure: { nil })
  engine.ingestObservations()
  return Fixture(engine: engine, settings: settings, app: app, device: device, runtime: runtime)
}

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {
  @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
  func eqSettingsAreCarried() async throws {
    let fix = makeFixture()
    let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
    fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).eqSettings == custom)
    await fix.engine.shutdown()
  }

  @Test(
    "autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled", arguments: [true, false])
  func autoEQPreampEnabledMirrored(value: Bool) async throws {
    let fix = makeFixture()
    fix.settings.autoEQPreampEnabled = value
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).autoEQPreampEnabled == value)
    await fix.engine.shutdown()
  }

  @Test(
    "loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
    arguments: [true, false])
  func loudnessCompensationFlagMirrored(value: Bool) async throws {
    let fix = makeFixture()
    var settings = fix.settings.appSettings
    settings.loudnessCompensationEnabled = value
    fix.settings.updateAppSettings(settings)
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).loudnessCompensationEnabled == value)
    await fix.engine.shutdown()
  }

  @Test(
    "loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
    arguments: [true, false])
  func loudnessEqualizerFlagMirrored(value: Bool) async throws {
    let fix = makeFixture()
    var settings = fix.settings.appSettings
    settings.loudnessEqualizationEnabled = value
    fix.settings.updateAppSettings(settings)
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).loudnessEqualizerSettings.enabled == value)
    await fix.engine.shutdown()
  }

  @Test("loudnessVolume = currentDeviceVolume × per-app volume")
  func loudnessVolumeIsProduct() async throws {
    let fix = makeFixture(deviceVolume: 0.5)
    fix.engine.setVolume(for: fix.app, to: 0.4)
    await fix.activate()
    #expect(abs(try #require(capturedInitial(fix)).loudnessVolume - 0.2) < 1e-6)
    await fix.engine.shutdown()
  }

  @Test("autoEQProfile is nil when the device does not support AutoEQ")
  func autoEQNilForUnsupportedDevice() async throws {
    let fix = makeFixture(supportsAutoEQ: false)
    fix.settings.setAutoEQSelection(
      for: fix.device.uid, to: AutoEQSelection(profileID: "any-id", isEnabled: true))
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).autoEQProfile == nil)
    await fix.engine.shutdown()
  }

  @Test("autoEQProfile is nil when no selection is persisted for the device")
  func autoEQNilWithNoSelection() async throws {
    let fix = makeFixture()
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).autoEQProfile == nil)
    await fix.engine.shutdown()
  }

  @Test("autoEQProfile is nil when the selection is disabled")
  func autoEQNilWhenSelectionDisabled() async throws {
    let fix = makeFixture()
    fix.settings.setAutoEQSelection(
      for: fix.device.uid, to: AutoEQSelection(profileID: "any-id", isEnabled: false))
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).autoEQProfile == nil)
    await fix.engine.shutdown()
  }

  @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
  func autoEQNilWhenProfileNotCached() async throws {
    let fix = makeFixture()
    fix.settings.setAutoEQSelection(
      for: fix.device.uid, to: AutoEQSelection(profileID: "missing-id", isEnabled: true))
    await fix.activate()
    #expect(try #require(capturedInitial(fix)).autoEQProfile == nil)
    await fix.engine.shutdown()
  }

  @Test("Initial commit is the first event the prepared native owner observes")
  func activateIsFirstEvent() async throws {
    let fix = makeFixture()
    await fix.activate()
    let first = try #require(fix.lastTap?.events.first)
    if case .commit = first {
    } else {
      Issue.record("First event was \(first), expected initial commit")
    }
    await fix.engine.shutdown()
  }

  @Test("No post-initial processing update runs before initial native commit")
  func noMutationBeforeActivate() async throws {
    let fix = makeFixture()
    fix.settings.setAutoEQSelection(
      for: fix.device.uid, to: AutoEQSelection(profileID: "missing-id", isEnabled: true))
    fix.settings.setEQSettings(
      EQSettings(bandGains: Array(repeating: 1, count: 10)), for: fix.app.persistenceIdentifier)
    var settings = fix.settings.appSettings
    settings.loudnessCompensationEnabled = true
    settings.loudnessEqualizationEnabled = true
    fix.settings.updateAppSettings(settings)
    await fix.activate()
    let tap = try #require(fix.lastTap)
    let index = try #require(tap.events.firstIndex { if case .commit = $0 { true } else { false } })
    for event in tap.events.prefix(index) {
      if case .update = event {
        Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
      }
    }
    let initial = try #require(capturedInitial(fix))
    #expect(initial.eqSettings.bandGains == Array(repeating: 1, count: 10))
    #expect(initial.loudnessCompensationEnabled && initial.loudnessEqualizerSettings.enabled)
    await fix.engine.shutdown()
  }

  @Test("Cache-miss AutoEQ remains unavailable without changing the enabled selection")
  func cacheMissPreservesUnavailableSelection() async throws {
    // Original ID cacheMissTriggersPostActivateNilSet: establish the same nil correction
    // in complete initial state, while exposing missing data without rewriting its desired ID.
    let fix = makeFixture()
    fix.settings.setAutoEQSelection(
      for: fix.device.uid, to: AutoEQSelection(profileID: "missing-id", isEnabled: true))
    await fix.activate()
    if case .commit = fix.lastTap?.events.first {
    } else {
      Issue.record("Initial commit was not first event")
    }
    #expect(try #require(capturedInitial(fix)).autoEQProfile == nil)
    #expect(fix.engine.controller.unavailableAutoEQProfiles[fix.device.uid] == "missing-id")
    #expect(
      fix.engine.controller.activeDeviceUIDs(for: fix.app.persistenceIdentifier) == [fix.device.uid]
    )
    #expect(fix.engine.controller.lastFailure == nil)
    let desired = try #require(fix.settings.getAutoEQSelection(for: fix.device.uid))
    #expect(desired.profileID == "missing-id" && desired.isEnabled)
    await fix.engine.shutdown()
  }
}

@MainActor
private func capturedInitial(_ fix: Fixture) -> TapInitialState? {
  guard let route = fix.lastTap else { return nil }
  for event in route.events { if case .commit(let state) = event { return state.processing } }
  return nil
}

@Suite("Audio route — required Control value contract")
@MainActor
struct AudioRoutePortContractTests {
  @Test("Empty Control state prepares unity volume, independent mute, flat EQ and no correction")
  func controlInitialStateDefaults() {
    let volume = VolumeState()
    let initial = TapInitialState()
    #expect(volume.getVolume(for: 1) == 1)
    #expect(volume.getMute(for: 1) == false)
    #expect(volume.getBoost(for: 1) == .x1)
    #expect(initial.eqSettings == .flat)
    #expect(initial.autoEQProfile == nil)
    #expect(initial.autoEQPreampEnabled == false)
    #expect(initial.loudnessVolume == 1)
    #expect(initial.loudnessCompensationEnabled == false)
    #expect(initial.loudnessEqualizerSettings.enabled == false)
  }
}

@Suite("AudioEngine — explicit runtime and capture intent boundaries")
@MainActor
struct AudioEngineRouteBoundaryTests {
  @Test("Passive capture wish does not construct native resources or discard the requested output")
  func unknownAuthorizationPreservesRequest() async {
    // The new contract does not infer authorization. Absence of explicit capture wish is passive.
    let setup = makeBoundarySetup()
    let runtime = RecordingAudioRoutingRuntime()
    let engine = makeEngine(setup, runtime: runtime)
    engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
    await engine.controller.waitForCurrentWork()
    #expect(runtime.requests.isEmpty && engine.controller.captureIntent == .none)
    #expect(engine.controller.activeDeviceUIDs(for: setup.app.persistenceIdentifier).isEmpty)
    #expect(
      setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    await engine.shutdown()
  }

  @Test("An unavailable live adapter reports failure instead of pretending capture started")
  func unavailableRuntimePreservesRequest() async {
    let setup = makeBoundarySetup()
    let engine = makeEngine(setup, runtime: nil)
    engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
    engine.controller.perform(.requestCaptureStart)
    await engine.controller.waitForCurrentWork()
    #expect(engine.controller.activeDeviceUIDs(for: setup.app.persistenceIdentifier).isEmpty)
    #expect(engine.controller.lastFailure?.kind == .unavailable)
    #expect(engine.controller.lastFailure?.stage == "prepare")
    #expect(
      setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    await engine.shutdown()
  }

  @Test("A failed replacement disposes only the candidate and preserves the active route")
  func failedActivationKeepsOldRoute() async throws {
    let setup = makeBoundarySetup()
    let other = AudioDevice(
      id: 100, uid: "uid-failed", name: "Other", icon: nil, supportsAutoEQ: true, bindingRevision: 1
    )
    setup.devices.addOutputDevice(other)
    setup.volume.volumes[other.id] = 1
    let runtime = RecordingAudioRoutingRuntime()
    let engine = makeEngine(setup, runtime: runtime)
    engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
    engine.controller.perform(.requestCaptureStart)
    await engine.controller.waitForCurrentWork()
    runtime.activationError = AudioRouteFailure(
      stage: "activate", message: "Expected activation failure")
    engine.setDevice(for: setup.app, deviceUID: other.uid)
    await engine.controller.waitForCurrentWork()
    #expect(runtime.routes.count == 2)
    let candidate = try #require(runtime.routes.last)
    try await candidate.waitUntilRetired()
    #expect(
      engine.controller.activeDeviceUIDs(for: setup.app.persistenceIdentifier) == [setup.device.uid]
    )
    #expect(engine.controller.lastFailure?.stage == "activate")
    #expect(setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == other.uid)
    #expect(runtime.routes[0].retired == false)
    #expect(candidate.events.contains(.cancel) && candidate.retired)
    await engine.shutdown()
  }

  @Test("A vanished process releases its route but keeps saved app preferences")
  func vanishedProcessReleasesRoute() async throws {
    let setup = makeBoundarySetup()
    let runtime = RecordingAudioRoutingRuntime()
    let engine = makeEngine(setup, runtime: runtime)
    engine.setVolume(for: setup.app, to: 0.25)
    engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
    engine.controller.perform(.requestCaptureStart)
    await engine.controller.waitForCurrentWork()
    let route = try #require(runtime.routes.first)
    setup.processes.activeApps = []
    engine.ingestObservations()
    try await route.waitUntilRetired()
    #expect(engine.apps.isEmpty)
    #expect(engine.controller.activeDeviceUIDs(for: setup.app.persistenceIdentifier).isEmpty)
    #expect(
      engine.volumeState.getVolume(for: setup.app.id)
        == setup.settings.appSettings.defaultNewAppVolume)
    #expect(setup.settings.getVolume(for: setup.app.persistenceIdentifier) == 0.25)
    #expect(
      setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    await engine.shutdown()
  }

  @Test(
    "Actual profile cache retains values without inventing absent profiles",
    arguments: [false, true])
  func profileCacheRetainsValues(loadAtInitialization: Bool) {
    let profile = AutoEQProfile(
      id: "cached", name: "Cached", source: .imported, preampDB: -3,
      filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 2, q: 0.7)])
    let cache = AutoEQProfileCache(profiles: loadAtInitialization ? [profile] : [])
    if !loadAtInitialization { cache.store(profile) }
    #expect(cache.profile(for: "cached") == profile)
    #expect(cache.profile(for: "missing") == nil)
  }

  private typealias Setup = (
    settings: SettingsManager, devices: MockAudioDeviceMonitor,
    volume: MockDeviceVolumeProviding, processes: StubProcessMonitor, app: AudioApp,
    device: AudioDevice
  )
  private func makeBoundarySetup() -> Setup {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: TestLaunchAtLoginService())
    let devices = MockAudioDeviceMonitor()
    let device = AudioDevice(
      id: 99, uid: "uid-existing", name: "Existing", icon: nil, supportsAutoEQ: true,
      bindingRevision: 1)
    devices.addOutputDevice(device)
    let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
    volume.defaultDeviceUID = device.uid
    volume.volumes[device.id] = 1
    volume.muteStates[device.id] = false
    let app = AudioApp(
      id: 12345, processObjectIDs: [], name: "RouteTest", icon: NSImage(),
      bundleID: "com.test.route", processRevision: 1)
    let processes = StubProcessMonitor()
    processes.activeApps = [app]
    return (settings, devices, volume, processes, app, device)
  }
  private func makeEngine(_ setup: Setup, runtime: (any AudioRoutingRuntime)?) -> AudioEngine {
    let controller = AudioController(
      settings: setup.settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let engine = AudioEngine(
      controller: controller, settingsManager: setup.settings,
      deviceObservations: setup.devices, processObservations: setup.processes,
      deviceVolumeMonitor: setup.volume, readOutputFailure: { nil })
    engine.ingestObservations()
    return engine
  }
}
