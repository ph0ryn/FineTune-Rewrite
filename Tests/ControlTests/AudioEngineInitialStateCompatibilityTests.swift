// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune (FineTuneTests/{AudioEngineTapInitialStateTests,
// AudioEngineToggleMuteTests}.swift)
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51

import FineTuneControl
import FineTuneDomain
import Foundation
import Testing

@MainActor
private final class CompatControlSettingsStore: AudioControlSettingsStore {
  var appSettings = AppSettings()
  var volumes: [String: Float] = [:]
  var mutes: [String: Bool] = [:]
  var boosts: [String: BoostLevel] = [:]
  var modes: [String: DeviceSelectionMode] = [:]
  var selectedUIDs: [String: Set<String>] = [:]
  var routing: [String: String] = [:]
  var followDefaultFlags: [String: Bool] = [:]
  var eqByID: [String: EQSettings] = [:]
  var pinnedIDs: Set<String> = []
  var ignoredIDs: Set<String> = []
  var autoEQSelections: [String: AutoEQSelection] = [:]
  var favoriteAutoEQProfileIDs: Set<String> = []
  var autoEQPreampEnabled = false
  var devicePriorityOrder: [String] = []

  func getVolume(for identifier: String) -> Float? { volumes[identifier] }
  func setVolume(for identifier: String, to volume: Float) { volumes[identifier] = volume }
  func getMute(for identifier: String) -> Bool? { mutes[identifier] }
  func setMute(for identifier: String, to muted: Bool) { mutes[identifier] = muted }
  func getBoost(for identifier: String) -> BoostLevel? { boosts[identifier] }
  func setBoost(for identifier: String, to boost: BoostLevel) { boosts[identifier] = boost }
  func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? { modes[identifier] }
  func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
    modes[identifier] = mode
  }
  func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? { selectedUIDs[identifier] }
  func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
    selectedUIDs[identifier] = uids
  }

  func updateAppSettings(_ settings: AppSettings) { appSettings = settings }
  func resetAllSettings() {
    volumes.removeAll()
    mutes.removeAll()
    boosts.removeAll()
    modes.removeAll()
    selectedUIDs.removeAll()
    routing.removeAll()
    followDefaultFlags.removeAll()
    eqByID.removeAll()
    pinnedIDs.removeAll()
    ignoredIDs.removeAll()
    autoEQSelections.removeAll()
  }
  func getDeviceRouting(for identifier: String) -> String? { routing[identifier] }
  func setDeviceRouting(for identifier: String, deviceUID: String) {
    routing[identifier] = deviceUID
  }
  func isFollowingDefault(for identifier: String) -> Bool {
    followDefaultFlags[identifier] ?? true
  }
  func setFollowDefault(for identifier: String) {
    followDefaultFlags[identifier] = true
  }
  func getEQSettings(for identifier: String) -> EQSettings { eqByID[identifier] ?? .flat }
  func setEQSettings(_ settings: EQSettings, for identifier: String) {
    eqByID[identifier] = settings
  }
  func isPinned(_ identifier: String) -> Bool { pinnedIDs.contains(identifier) }
  func isIgnored(_ identifier: String) -> Bool { ignoredIDs.contains(identifier) }
  func setAppPinned(_ identifier: String, pinned: Bool, displayName: String?, bundleID: String?) {
    if pinned { pinnedIDs.insert(identifier) } else { pinnedIDs.remove(identifier) }
  }
  func setAppIgnored(_ identifier: String, ignored: Bool, displayName: String?, bundleID: String?) {
    if ignored { ignoredIDs.insert(identifier) } else { ignoredIDs.remove(identifier) }
  }
  func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
    autoEQSelections[deviceUID]
  }
  func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
    autoEQSelections[deviceUID] = selection
  }
  func setAutoEQFavorite(profileID: String, favorite: Bool) {
    if favorite {
      favoriteAutoEQProfileIDs.insert(profileID)
    } else {
      favoriteAutoEQProfileIDs.remove(profileID)
    }
  }
}

@MainActor
private final class CompatPreparedRoute: PreparedAudioRoute {
  let key: AudioRouteKey
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  var events: [String] = []
  var recordedLevels: [AudioOutputLevels] = []
  var retireCalls = 0

  init(key: AudioRouteKey) {
    self.key = key
  }

  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append("startMuted")
    let obs = AudioRouteObservation(
      key: key, phase: .started, acceptedRevision: state.revision, appliedRevision: state.revision)
    onObservation?(obs)
    return obs
  }

  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append("commit")
    let obs = AudioRouteObservation(
      key: key, phase: .committed, acceptedRevision: state.revision, appliedRevision: state.revision
    )
    onObservation?(obs)
    return obs
  }

  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    events.append("update")
    let obs = AudioRouteObservation(
      key: key, phase: .committed, acceptedRevision: state.revision, appliedRevision: state.revision
    )
    onObservation?(obs)
    return obs
  }

  func requestLevels(_ levels: AudioOutputLevels) {
    events.append("requestLevels")
    recordedLevels.append(levels)
  }

  func cancel() {
    events.append("cancel")
  }

  func retire() async -> AudioRetirementResult {
    retireCalls += 1
    events.append("retire")
    return .retired
  }
}

@MainActor
private final class CompatRoutingRuntime: AudioRoutingRuntime {
  var preparedRequests: [AudioRouteRequest] = []
  var createdRoutes: [CompatPreparedRoute] = []
  var events: [String] = []

  func requestCleanupRetry() {}

  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    events.append("prepare")
    preparedRequests.append(request)
    let route = CompatPreparedRoute(key: request.key)
    createdRoutes.append(route)
    return route
  }
}

@MainActor
@Suite("Upstream AudioEngine InitialState & ToggleMute Compatibility")
struct UpstreamAudioEngineInitialStateCompatibilityTests {

  private static let appID = "com.example.player"
  private static let deviceUID = "dev-uid-1"

  private static func makeController(
    store: CompatControlSettingsStore,
    runtime: CompatRoutingRuntime,
    profiles: [String: AutoEQProfile] = [:]
  ) -> AudioController {
    AudioController(
      settings: store,
      runtime: runtime,
      profileLookup: { profiles[$0] },
      readDefaultRoutingDecision: { .followObserved }
    )
  }

  private static func seedDefaultRoute(
    controller: AudioController,
    supportsAutoEQ: Bool = true,
    processingGain: Float = 1.0,
    outputVolume: Float? = 1.0
  ) async {
    controller.perform(.requestCaptureStart)
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: deviceUID,
          bindingRevision: 1,
          supportsAutoEQ: supportsAutoEQ,
          processingGain: processingGain,
          volume: outputVolume,
          isMuted: false
        )
      ],
      defaultUID: deviceUID
    )
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: appID,
        processID: 4242,
        processRevision: 1,
        displayName: "Player",
        bundleID: appID
      )
    ])
    await controller.waitForCurrentWork()
  }

  private static func makeProfile(id: String) -> AutoEQProfile {
    AutoEQProfile(
      id: id,
      name: "Test Profile",
      source: .imported,
      preampDB: -3.5,
      filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3.5, q: 1.4)],
      optimizedSampleRate: 48000
    )
  }

  @Test("TapInitialState defaults are flat, disabled, unity volume")
  func tapInitialStateDefaults() {
    let state = TapInitialState()
    #expect(state.eqSettings == .flat)
    #expect(state.autoEQProfile == nil)
    #expect(!state.autoEQPreampEnabled)
    #expect(state.loudnessVolume == 1)
    #expect(!state.loudnessCompensationEnabled)
    #expect(!state.loudnessEqualizerSettings.enabled)
  }

  @Test("Projects stored EQ settings onto route initial processing state")
  func initialStateIncludesEQSettings() async throws {
    let store = CompatControlSettingsStore()
    var eq = EQSettings.flat
    eq.bandGains[3] = 6
    store.setEQSettings(eq, for: Self.appID)
    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(store: store, runtime: runtime)

    await Self.seedDefaultRoute(controller: controller)
    let prepared = try #require(runtime.preparedRequests.last)
    #expect(prepared.initialState.processing.eqSettings == eq)
  }

  @Test(
    "Projects AutoEQ preamp and resolved profile when device supports AutoEQ and selection is enabled"
  )
  func initialStateIncludesAutoEQAndPreamp() async throws {
    let profile = Self.makeProfile(id: "profile-hd650")
    let store = CompatControlSettingsStore()
    store.autoEQPreampEnabled = true
    store.setAutoEQSelection(
      for: Self.deviceUID,
      to: AutoEQSelection(profileID: profile.id, isEnabled: true)
    )
    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(
      store: store, runtime: runtime, profiles: [profile.id: profile])

    await Self.seedDefaultRoute(controller: controller, supportsAutoEQ: true)
    let prepared = try #require(runtime.preparedRequests.last)
    #expect(prepared.initialState.processing.autoEQProfile == profile)
    #expect(prepared.initialState.processing.autoEQPreampEnabled)
  }

  @Test("Omits AutoEQ profile when selection is nil, disabled, or device does not support AutoEQ")
  func initialStateOmitsAutoEQInNonEligibleCases() async {
    let profile = Self.makeProfile(id: "profile-1")

    // Case 1: no selection
    do {
      let store = CompatControlSettingsStore()
      let runtime = CompatRoutingRuntime()
      let controller = Self.makeController(
        store: store, runtime: runtime, profiles: [profile.id: profile])
      await Self.seedDefaultRoute(controller: controller, supportsAutoEQ: true)
      #expect(runtime.preparedRequests.last?.initialState.processing.autoEQProfile == nil)
    }

    // Case 2: disabled selection
    do {
      let store = CompatControlSettingsStore()
      store.setAutoEQSelection(
        for: Self.deviceUID,
        to: AutoEQSelection(profileID: profile.id, isEnabled: false)
      )
      let runtime = CompatRoutingRuntime()
      let controller = Self.makeController(
        store: store, runtime: runtime, profiles: [profile.id: profile])
      await Self.seedDefaultRoute(controller: controller, supportsAutoEQ: true)
      #expect(runtime.preparedRequests.last?.initialState.processing.autoEQProfile == nil)
    }

    // Case 3: device does not support AutoEQ
    do {
      let store = CompatControlSettingsStore()
      store.setAutoEQSelection(
        for: Self.deviceUID,
        to: AutoEQSelection(profileID: profile.id, isEnabled: true)
      )
      let runtime = CompatRoutingRuntime()
      let controller = Self.makeController(
        store: store, runtime: runtime, profiles: [profile.id: profile])
      await Self.seedDefaultRoute(controller: controller, supportsAutoEQ: false)
      #expect(runtime.preparedRequests.last?.initialState.processing.autoEQProfile == nil)
    }
  }

  @Test(
    "AutoEQ profile cache miss yields nil profile, surfaces unavailableAutoEQProfiles, and preserves selection"
  )
  func autoEQCacheMissPreservesSelection() async throws {
    let store = CompatControlSettingsStore()
    let selection = AutoEQSelection(profileID: "missing-profile", isEnabled: true)
    store.setAutoEQSelection(for: Self.deviceUID, to: selection)
    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(store: store, runtime: runtime, profiles: [:])

    await Self.seedDefaultRoute(controller: controller, supportsAutoEQ: true)
    let prepared = try #require(runtime.preparedRequests.last)
    #expect(prepared.initialState.processing.autoEQProfile == nil)
    #expect(controller.unavailableAutoEQProfiles[Self.deviceUID] == "missing-profile")
    #expect(store.getAutoEQSelection(for: Self.deviceUID) == selection)
  }

  @Test(
    "Projects loudness equalizer settings, loudness compensation flag, and unboosted loudness volume"
  )
  func initialStateIncludesLoudnessSettingsAndVolume() async throws {
    let store = CompatControlSettingsStore()
    var settings = AppSettings()
    settings.loudnessCompensationEnabled = true
    settings.loudnessEqualizationEnabled = true
    store.updateAppSettings(settings)
    store.setVolume(for: Self.appID, to: 0.6)
    store.setBoost(for: Self.appID, to: .x2)

    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(store: store, runtime: runtime)
    await Self.seedDefaultRoute(controller: controller, processingGain: 0.5, outputVolume: 0.5)

    let prepared = try #require(runtime.preparedRequests.last)
    #expect(prepared.initialState.processing.loudnessCompensationEnabled)
    #expect(prepared.initialState.processing.loudnessEqualizerSettings.enabled)
    #expect(abs(prepared.initialState.processing.loudnessVolume - 0.3) < 1e-5)
    #expect(abs(prepared.initialState.effectiveGain - 0.6) < 1e-5)
  }

  @Test("Prepare precedes commit and route emits no levels update before initial activation")
  func prepareOccursBeforeCommitWithNoPrematureLevels() async throws {
    let store = CompatControlSettingsStore()
    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(store: store, runtime: runtime)

    await Self.seedDefaultRoute(controller: controller)
    let route = try #require(runtime.createdRoutes.last)
    #expect(runtime.events == ["prepare"])
    #expect(route.events.first == "commit")
    let commitIndex = try #require(route.events.firstIndex(of: "commit"))
    let firstLevelsIndex = route.events.firstIndex(of: "requestLevels")
    #expect(firstLevelsIndex.map { $0 > commitIndex } ?? true)
  }

  @Test(
    "VolumeState default mute is false and toggleMuted flips mute state in store and active route")
  func toggleMutedRoundTrip() async throws {
    let volumeState = VolumeState()
    #expect(!volumeState.getMute(for: 99))
    volumeState.setMute(for: 99, to: true, identifier: Self.appID)
    #expect(volumeState.getMute(for: 99))

    let store = CompatControlSettingsStore()
    let runtime = CompatRoutingRuntime()
    let controller = Self.makeController(store: store, runtime: runtime)
    await Self.seedDefaultRoute(controller: controller)
    let route = try #require(runtime.createdRoutes.last)

    controller.perform(.toggleMuted(identifier: Self.appID))
    #expect(controller.isMuted(for: Self.appID))
    #expect(store.getMute(for: Self.appID) == true)
    #expect(route.recordedLevels.last?.isMuted == true)

    controller.perform(.toggleMuted(identifier: Self.appID))
    #expect(!controller.isMuted(for: Self.appID))
    #expect(store.getMute(for: Self.appID) == false)
    #expect(route.recordedLevels.last?.isMuted == false)
    #expect(route.retireCalls == 0)
  }
}
