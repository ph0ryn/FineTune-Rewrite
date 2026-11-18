import FineTuneControl
import FineTuneDomain
import Testing

@Suite(
  "Control: AudioController lifecycle, preparation retries, and capture intent",
  .timeLimit(.minutes(1)))
@MainActor
struct AudioControllerLifecycleTests {
  private let application = AudioApplicationDescriptor(
    identifier: "unit.player", processID: 101, processRevision: 1,
    displayName: "Player", bundleID: "unit.player")
  private let a = AudioOutputDescriptor(
    uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 0.25, volume: 0.6,
    isMuted: false)
  private let b = AudioOutputDescriptor(
    uid: "B", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 0.8,
    isMuted: false)

  private func makeController(
    settings: InMemoryControlSettingsStore,
    runtime: ControlledRoutingRuntime,
    profileLookup: @escaping @MainActor (String) -> AutoEQProfile? = { _ in nil }
  ) -> AudioController {
    AudioController(
      settings: settings, runtime: runtime, profileLookup: profileLookup,
      readDefaultRoutingDecision: { .followObserved })
  }

  private func waitForPreparationStarted(
    count: Int, runtime: ControlledRoutingRuntime, controller: AudioController
  ) async throws {
    do {
      try await runtime.waitForPreparationStarted(count: count)
    } catch {
      runtime.releaseAllHeldGates()
      await controller.shutdown()
      throw error
    }
  }

  @Test(
    "A failed capture attempt is not reopened by passive observations",
    arguments: [false, true])
  func failedPreparationDoesNotRetryFromPassiveObservations(readTapFailure: Bool) async {
    let failure = AudioRouteFailure(
      kind: readTapFailure ? .unsupported : .nativeFailure,
      stage: readTapFailure ? "inspectTap" : "createTap", code: -7201,
      message: "The actual preparation failed without an authorization result.")
    let settings = InMemoryControlSettingsStore(explicitUserCaptureEnabled: true)
    let runtime = ControlledRoutingRuntime()
    runtime.prepareFailure = failure
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(controller.routeFailure == failure)

    for _ in 0..<3 {
      controller.observeOutputs([a], defaultUID: "A")
      controller.observeApplications([application])
      await controller.waitForCurrentWork()
    }
    #expect(runtime.requests.count == 1)
    #expect(runtime.cleanupRetryRequests == 0)
    #expect(controller.routeFailure == failure)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test("Passive binding churn cannot stack acquisitions or erase the pending native failure")
  func pendingPassiveChurnDoesNotAccumulateAcquisitions() async throws {
    let failure = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7211,
      message: "The held native preparation returned E1.")
    let settings = InMemoryControlSettingsStore(explicitUserCaptureEnabled: true)
    let runtime = ControlledRoutingRuntime()
    runtime.holdPreparation = ["A"]
    runtime.onPrepareRequest = { _, index in
      index == 0
        ? failure
        : AudioRouteFailure(
          kind: .nativeFailure, stage: "createTap", code: -7212,
          message: "Unexpected second acquisition E2.")
    }
    defer { runtime.releaseAllHeldGates() }
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    try await waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)
    #expect(runtime.requests.count == 1)

    for revision in UInt64(2)...4 {
      controller.observeApplications([
        AudioApplicationDescriptor(
          identifier: "unit.player", processID: 101, processRevision: revision,
          displayName: "Player", bundleID: "unit.player")
      ])
      controller.observeOutputs(
        [
          AudioOutputDescriptor(
            uid: "A", bindingRevision: revision, supportsAutoEQ: true, processingGain: 0.25,
            volume: 0.6, isMuted: false)
        ], defaultUID: "A")
    }
    #expect(runtime.requests.count == 1)
    #expect(runtime.maximumOutstandingPreparations == 1)

    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(runtime.cleanupRetryRequests == 0)
    #expect(controller.routeFailure == failure)
    #expect(!runtime.cancelledHeldPreparation)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)

    for revision in UInt64(5)...6 {
      controller.observeApplications([
        AudioApplicationDescriptor(
          identifier: "unit.player", processID: 101, processRevision: revision,
          displayName: "Player", bundleID: "unit.player")
      ])
      controller.observeOutputs(
        [
          AudioOutputDescriptor(
            uid: "A", bindingRevision: revision, supportsAutoEQ: true, processingGain: 0.25,
            volume: 0.6, isMuted: false)
        ], defaultUID: "A")
      await controller.waitForCurrentWork()
    }
    #expect(controller.routeFailure == failure)
    #expect(runtime.requests.count == 1)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test(
    "An explicit same-target retry starts a fresh attempt before the old one settles",
    arguments: [false, true])
  func explicitSameTargetRetrySupersedesPendingAttempt(retryStart: Bool) async throws {
    let failure1 = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7211,
      message: "The held native preparation returned E1.")
    let failure2 = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7212,
      message: "Retried preparation returned E2.")
    let settings = InMemoryControlSettingsStore(explicitUserCaptureEnabled: true)
    let runtime = ControlledRoutingRuntime()
    runtime.holdPreparation = ["A"]
    runtime.onPrepareRequest = { _, index in index == 0 ? failure1 : failure2 }
    defer { runtime.releaseAllHeldGates() }
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    try await waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)

    if retryStart {
      controller.perform(.requestCaptureStart)
    } else {
      controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["A"]))
    }
    try await waitForPreparationStarted(count: 2, runtime: runtime, controller: controller)
    #expect(runtime.requests.count == 2)
    let retriedFailure = controller.captureRetryFailure
    #expect(retriedFailure == failure2)
    #expect(controller.routeFailure == failure2)

    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(controller.captureRetryFailure == failure2)
    #expect(controller.routeFailure == failure2)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(controller.captureRetryFailure == failure2)
    #expect(!controller.knownPermissionDenied)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test("A successful pending attempt retires its stale owner and uses only the latest binding")
  func successfulPendingReplacementUsesLatestBinding() async throws {
    let settings = InMemoryControlSettingsStore(explicitUserCaptureEnabled: true)
    let runtime = ControlledRoutingRuntime()
    runtime.holdPreparation = ["A"]
    defer { runtime.releaseAllHeldGates() }
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    try await waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)

    for revision in UInt64(2)...3 {
      controller.observeApplications([
        AudioApplicationDescriptor(
          identifier: "unit.player", processID: 101, processRevision: revision,
          displayName: "Player", bundleID: "unit.player")
      ])
      controller.observeOutputs(
        [
          AudioOutputDescriptor(
            uid: "A", bindingRevision: revision, supportsAutoEQ: true, processingGain: 0.25,
            volume: 0.6, isMuted: false)
        ], defaultUID: "A")
    }
    #expect(runtime.requests.count == 1)
    runtime.releasePreparation("A")
    try await waitForPreparationStarted(count: 2, runtime: runtime, controller: controller)
    await controller.waitForCurrentWork()

    #expect(runtime.requests.count == 2)
    #expect(runtime.maximumOutstandingPreparations == 1)
    #expect(runtime.requests.last?.processRevision == 3)
    let stale = try #require(runtime.handles.first)
    let current = try #require(runtime.handles.last)
    #expect(stale.key != current.key)
    #expect(stale.retired && stale.commits.isEmpty)
    #expect(current.commits.count == 1)
    #expect(controller.activeDeviceUIDs(for: "unit.player") == ["A"])
    #expect(controller.captureRetryFailure == nil)
    #expect(!controller.knownPermissionDenied)
    await controller.shutdown()
    #expect(current.retired)
  }

  @Test("Blocked preparation commits latest settings, gain, and profile once resumed")
  func callbacksWhilePreparationIsBlockedCommitLatestState() async throws {
    let settings = InMemoryControlSettingsStore()
    let initialProfile = AutoEQProfile(
      id: "unit-profile", name: "Initial", source: .imported, preampDB: -3, filters: [])
    let latestProfile = AutoEQProfile(
      id: "unit-profile", name: "Latest", source: .imported, preampDB: -6, filters: [])
    let profiles = MutableBox<[String: AutoEQProfile]>([initialProfile.id: initialProfile])
    settings.setAutoEQSelection(
      for: "A", to: AutoEQSelection(profileID: initialProfile.id, isEnabled: true))
    let runtime = ControlledRoutingRuntime()
    runtime.holdPreparation = ["A"]
    let fullOutput = AudioOutputDescriptor(
      uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = makeController(
      settings: settings, runtime: runtime, profileLookup: { profiles.value[$0] })
    controller.observeOutputs([fullOutput], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    try await runtime.wait("prepare:A")
    #expect(runtime.requests.first?.initialState.processing.autoEQProfile == initialProfile)

    var updated = settings.appSettings
    updated.loudnessCompensationEnabled = true
    controller.perform(.updateAppSettings(updated))
    var second = settings.appSettings
    second.defaultNewAppVolume = 0.23
    controller.perform(.updateAppSettings(second))
    controller.perform(.editGain(identifier: application.identifier, gain: 0.42))
    profiles.value[latestProfile.id] = latestProfile
    controller.perform(.profileAvailabilityChanged(profileID: latestProfile.id))

    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()
    let committed = try #require(runtime.handle("A")?.commits.last)
    #expect(committed.effectiveGain == 0.42)
    #expect(committed.processing.autoEQProfile == latestProfile)
    #expect(committed.processing.loudnessCompensationEnabled)
    #expect(runtime.requests.count == 1)
    await controller.shutdown()
    #expect(settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Typed known denial blocks reconnect work until a fresh explicit retry")
  func knownDenialDoesNotRetryAutomatically() async {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    runtime.prepareFailure = AudioRouteFailure(
      kind: .permissionDenied, stage: "unit", message: "Known denial")
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved }, deviceCommand: { _ in })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(controller.knownPermissionDenied && runtime.requests.count == 1)

    controller.observeOutputs([a, b], defaultUID: "A")
    controller.perform(.profileAvailabilityChanged(profileID: "anything"))
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1 && settings.appSettings.explicitUserCaptureEnabled)

    runtime.prepareFailure = nil
    controller.perform(.setDefaultDevice(scope: .output, uid: "B"))
    controller.observeOutputs([a, b], defaultUID: "B")
    await controller.waitForCurrentWork()
    #expect(controller.knownPermissionDenied && runtime.requests.count == 1)

    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(!controller.knownPermissionDenied && runtime.requests.count == 2)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    await controller.shutdown()
  }

  @Test("A superseded session denial cannot revoke the fresh explicit retry")
  func oldSessionDenialDoesNotRevokeRetry() async throws {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let denied = AudioRouteObservation(
      key: old.key, phase: .failed,
      failure: AudioRouteFailure(kind: .permissionDenied, stage: "unit", message: "Old session"))
    old.onObservation?(denied)
    #expect(controller.knownPermissionDenied)

    runtime.holdArmed = ["A"]
    controller.perform(.requestCaptureStart)
    try await runtime.wait("started:A")
    let replacement = try #require(runtime.handle("A"))
    #expect(replacement.key != old.key && !controller.knownPermissionDenied)
    old.onObservation?(denied)
    #expect(!controller.knownPermissionDenied)

    replacement.arm()
    await controller.waitForCurrentWork()
    #expect(!controller.knownPermissionDenied)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    #expect(replacement.rendering && !replacement.retired && old.retired)
    #expect(controller.captureRetryFailure == nil && controller.lastFailure == nil)
    #expect(controller.routeObservations[old.key]?.failure == denied.failure)
    await controller.shutdown()
  }

  @Test(
    "Failed observation preserves last-good owner; successful empty retires without erasing wishes",
    arguments: [false, true])
  func failureIsNotSuccessfulEmpty(applicationsEntry: Bool) async throws {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["A"]))
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))

    if applicationsEntry {
      controller.observeApplications([], failure: "Unit failed enumeration")
    } else {
      controller.observeOutputs([], defaultUID: nil, failure: "Unit failed enumeration")
    }
    #expect(controller.lastFailure != nil && route.retirementAttempts == 0)
    #expect(controller.applications == [application] && controller.outputs == [a])
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])

    if applicationsEntry {
      controller.observeApplications([])
    } else {
      controller.observeOutputs([], defaultUID: nil)
    }
    try await runtime.wait("retired:A")
    #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty && route.retired)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getDeviceRouting(for: application.identifier) == "A")
    await controller.shutdown()
  }

  @Test("Stop waits for a held preparation and retires only its late owner without committing")
  func stopCollectsLatePreparedOwner() async throws {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))

    runtime.holdPreparation = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("prepare:B")
    controller.perform(.stopCapture)
    var shutdownComplete = false
    let stopping = Task { @MainActor in
      await controller.shutdown()
      shutdownComplete = true
    }
    try await runtime.wait("retired:A")
    #expect(!shutdownComplete && old.retirementAttempts == 1)
    runtime.releasePreparation("B")
    await stopping.value

    let late = try #require(runtime.handle("B"))
    #expect(shutdownComplete && late.commits.isEmpty && late.cancelled && late.retired)
    #expect(old.retirementAttempts == 1 && late.retirementAttempts == 1)
    #expect(!old.rendering && !late.rendering && !settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getDeviceRouting(for: application.identifier) == "B")
  }

  @Test(
    "Confirmed reset-all synchronously clears wishes and cached active state then retires owners")
  func resetAllUsesSameControllerAndStore() async throws {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let controller = makeController(settings: settings, runtime: runtime)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.setGain(identifier: application.identifier, gain: 0.49))
    controller.perform(.setMuted(identifier: application.identifier, muted: true))
    controller.perform(.setBoost(identifier: application.identifier, boost: .x4))
    controller.perform(
      .setEQ(
        identifier: application.identifier,
        settings: EQSettings(bandGains: Array(repeating: 2, count: 10))))
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["A"]))
    controller.perform(.setGain(identifier: "unit.inactive", gain: 0.12))
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let owner = try #require(runtime.handle("A"))

    controller.perform(.resetAllSettings)
    #expect(
      controller.gain(for: application.identifier) == 1
        && !controller.isMuted(for: application.identifier))
    #expect(controller.boost(for: application.identifier) == .x1)
    #expect(
      settings.getVolume(for: "unit.inactive") == nil
        && settings.isFollowingDefault(for: application.identifier))
    #expect(settings.getEQSettings(for: application.identifier) == .flat)
    #expect(
      controller.captureIntent == .none && !settings.appSettings.explicitUserCaptureEnabled
        && owner.cancelled)

    await controller.shutdown()
    #expect(owner.retired && owner.retirementAttempts == 1 && runtime.requests.count == 1)
  }
}
