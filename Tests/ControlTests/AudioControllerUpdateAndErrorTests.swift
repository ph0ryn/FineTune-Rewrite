import FineTuneControl
import FineTuneDomain
import Testing

@Suite(
  "Control: AudioController updates, multi-output processing, and latched errors",
  .timeLimit(.minutes(1)))
@MainActor
struct AudioControllerUpdateAndErrorTests {
  private let application = AudioApplicationDescriptor(
    identifier: "unit.player", processID: 101, processRevision: 1,
    displayName: "Player", bundleID: "unit.player")
  private let a = AudioOutputDescriptor(
    uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 0.25, volume: 0.6,
    isMuted: false)
  private let b = AudioOutputDescriptor(
    uid: "B", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 0.8,
    isMuted: false)
  private let c = AudioOutputDescriptor(
    uid: "C", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
    isMuted: false)

  private func makeController(
    settings: InMemoryControlSettingsStore = InMemoryControlSettingsStore(),
    runtime: ControlledRoutingRuntime = ControlledRoutingRuntime(),
    profileLookup: @escaping @MainActor (String) -> AutoEQProfile? = { _ in nil }
  ) -> (AudioController, InMemoryControlSettingsStore, ControlledRoutingRuntime) {
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: profileLookup,
      readDefaultRoutingDecision: { .followObserved })
    return (controller, settings, runtime)
  }

  @Test("Blocked processing coalesces latest full state while hot levels remain immediate")
  func coalescesFullStateWithoutLosingHotLevels() async throws {
    let (controller, settings, runtime) = makeController()
    settings.setBoost(for: application.identifier, to: .x2)
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))

    runtime.holdUpdates = ["A"]
    var eq = EQSettings.flat
    eq.bandGains[0] = 7
    let nextUpdate = route.updates.count + 1
    controller.perform(.setEQ(identifier: application.identifier, settings: eq))
    try await runtime.wait("update:A:\(nextUpdate)")

    controller.perform(.setGain(identifier: application.identifier, gain: 0.2))
    controller.perform(.setMuted(identifier: application.identifier, muted: true))
    let latest = try #require(route.levels.last)
    #expect(abs(latest.effectiveGain - 0.1) < 0.000_001 && latest.isMuted)
    #expect(abs(latest.effectiveLoudnessVolume - 0.12) < 0.000_001)

    runtime.releaseUpdates("A")
    await controller.waitForCurrentWork()
    let full = try #require(route.updates.last)
    #expect(full.processing.eqSettings == eq && full.revision == latest.revision)
    #expect(full.effectiveGain == latest.effectiveGain && full.isMuted)
    #expect(controller.routeObservations[route.key]?.appliedRevision == nil)
    #expect(runtime.requests.count == 1)
    await controller.shutdown()
  }

  @Test(
    "Another app acquiring successfully cannot hide a still-silent active route's failure",
    arguments: [AudioRouteFailureKind.nativeFailure, .cancelled])
  func unrelatedAcquisitionPreservesActiveRouteFailure(kind: AudioRouteFailureKind) async throws {
    let (controller, settings, runtime) = makeController()
    let silentApplication = AudioApplicationDescriptor(
      identifier: "unit.silent", processID: 102, processRevision: 1, displayName: "Silent",
      bundleID: "unit.silent")
    controller.observeOutputs([b, c], defaultUID: "B")
    controller.observeApplications([application, silentApplication])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let failed = try #require(
      runtime.handles.first { $0.key.appIdentifier == silentApplication.identifier })
    #expect(settings.isFollowingDefault(for: application.identifier))
    #expect(settings.isFollowingDefault(for: silentApplication.identifier))
    #expect(failed.rendering && runtime.requests.count == 2)

    let failure = AudioRouteFailure(
      kind: kind, stage: "render", code: -5201, message: "Active B rendering failed")
    failed.rendering = false
    failed.onObservation?(AudioRouteObservation(key: failed.key, phase: .failed, failure: failure))
    #expect(controller.lastFailure == failure && controller.captureRetryFailure == nil)

    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    await controller.waitForCurrentWork()
    let recovered = try #require(runtime.handle("C"))
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["C"])
    #expect(recovered.rendering && !recovered.retired && runtime.requests.count == 3)
    #expect(controller.activeDeviceUIDs(for: silentApplication.identifier).isEmpty)
    #expect(!failed.rendering && !failed.retired && failed.retirementAttempts == 0)
    #expect(controller.routeObservations[failed.key]?.phase == .failed)
    #expect(controller.routeObservations[failed.key]?.failure == failure)
    #expect(controller.lastFailure == failure)

    runtime.holdUpdates = ["B"]
    runtime.holdRetirement = ["B"]
    controller.perform(
      .setRoute(identifier: silentApplication.identifier, mode: .single, uids: ["C"]))
    try await runtime.wait("retire:\(silentApplication.identifier):B")
    #expect(!failed.retired && runtime.handle("C")?.commits.isEmpty == true)
    #expect(controller.lastFailure == failure)
    runtime.releaseUpdates("B")
    failed.finishRetirement()
    await controller.waitForCurrentWork()

    #expect(controller.lastFailure == nil && controller.captureRetryFailure == nil)
    #expect(controller.activeDeviceUIDs(for: silentApplication.identifier) == ["C"])
    #expect(failed.retired && runtime.handle("C")?.rendering == true)
    await controller.shutdown()
    #expect(failed.retired && recovered.retired && !recovered.rendering)
  }

  @Test(
    "Multi output uses independent UID gain/profile; missing cache data keeps the saved selection")
  func independentUIDProcessingAndProfileRemoval() async throws {
    let settings = InMemoryControlSettingsStore()
    settings.setVolume(for: application.identifier, to: 0.3)
    settings.setBoost(for: application.identifier, to: .x3)
    settings.setDeviceRouting(for: application.identifier, deviceUID: "A")
    settings.setDeviceSelectionMode(for: application.identifier, to: .multi)
    settings.setSelectedDeviceUIDs(for: application.identifier, to: ["A", "B"])

    let first = AutoEQProfile(id: "pa", name: "A", source: .imported, preampDB: -3, filters: [])
    let second = AutoEQProfile(id: "pb", name: "B", source: .imported, preampDB: -6, filters: [])
    let profiles = MutableBox<[String: AutoEQProfile]>(["pa": first, "pb": second])
    settings.setAutoEQSelection(for: "A", to: AutoEQSelection(profileID: "pa", isEnabled: true))
    settings.setAutoEQSelection(for: "B", to: AutoEQSelection(profileID: "pb", isEnabled: true))

    let runtime = ControlledRoutingRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { profiles.value[$0] },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    #expect(runtime.requests.isEmpty && controller.captureIntent == .none)

    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let firstRoute = try #require(runtime.handle("A"))
    let secondRoute = try #require(runtime.handle("B"))
    let firstState = try #require(firstRoute.commits.first)
    let secondState = try #require(secondRoute.commits.first)
    #expect(abs(firstState.effectiveGain - 0.225) < 0.000_001)
    #expect(abs(secondState.effectiveGain - 0.9) < 0.000_001)
    #expect(abs(firstState.processing.loudnessVolume - 0.18) < 0.000_001)
    #expect(abs(secondState.processing.loudnessVolume - 0.24) < 0.000_001)
    #expect(firstState.processing.autoEQProfile?.id == "pa")
    #expect(secondState.processing.autoEQProfile?.id == "pb")

    profiles.value.removeValue(forKey: "pa")
    controller.perform(.profileAvailabilityChanged(profileID: "pa"))
    await controller.waitForCurrentWork()
    #expect(firstRoute.updates.last?.processing.autoEQProfile == nil)
    #expect(secondRoute.updates.last?.processing.autoEQProfile?.id == "pb")
    #expect(controller.unavailableAutoEQProfiles == ["A": "pa"])
    #expect(settings.getAutoEQSelection(for: "A")?.profileID == "pa")
    #expect(settings.getAutoEQSelection(for: "A")?.isEnabled == true)
    #expect(runtime.requests.count == 2 && !controller.knownPermissionDenied)
    await controller.shutdown()
  }

  @Test("An applied callback survives a delayed older receipt and hot levels never invent applied")
  func callbackBeforeOldReceiptPreservesApplied() async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))

    let previous = try #require(route.updates.last).revision
    let nextUpdate = route.updates.count + 1
    runtime.holdUpdates = ["A"]
    controller.perform(
      .setEQ(
        identifier: application.identifier,
        settings: EQSettings(bandGains: Array(repeating: 1, count: 10))))
    try await runtime.wait("update:A:\(nextUpdate)")

    let applied = try #require(route.updates.last).revision
    route.nextUpdateReceipt = AudioRouteObservation(
      key: route.key, phase: .accepted, acceptedRevision: previous, appliedRevision: previous)
    route.onObservation?(
      AudioRouteObservation(
        key: route.key, phase: .firstApplied, acceptedRevision: applied, appliedRevision: applied))
    controller.perform(.setGain(identifier: application.identifier, gain: 0.36))
    #expect(controller.routeObservations[route.key]?.appliedRevision == applied)

    runtime.holdUpdates = []
    runtime.releaseUpdates("A")
    await controller.waitForCurrentWork()
    let latest = try #require(route.updates.last).revision
    let observed = try #require(controller.routeObservations[route.key])
    #expect(latest > applied && observed.phase == .firstApplied)
    #expect(observed.acceptedRevision == latest && observed.appliedRevision == applied)
    #expect(route.levels.last?.revision == latest && runtime.requests.count == 1)
    await controller.shutdown()
  }

  @Test("A cleanup callback during initial commit is not erased by its later successful receipt")
  func commitReceiptCannotEraseLatchedError() async throws {
    let (controller, _, runtime) = makeController()
    runtime.commitCleanupFailure = AudioRouteFailure(
      stage: "commit-cleanup", message: "Latched commit cleanup")
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let candidate = try #require(runtime.handle("A"))
    #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty && candidate.cancelled)
    #expect(controller.lastFailure?.message == "Latched commit cleanup")
    await controller.shutdown()
    #expect(candidate.retired && !candidate.rendering)
  }

  @Test(
    "A delayed successful update receipt cannot continue full-state writes after a latched error")
  func updateReceiptCannotEraseLatchedError() async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))

    let expectedUpdates = route.updates.count + 1
    runtime.holdUpdates = ["A"]
    controller.perform(
      .setEQ(
        identifier: application.identifier,
        settings: EQSettings(bandGains: Array(repeating: 1, count: 10))))
    try await runtime.wait("update:A:\(expectedUpdates)")

    controller.perform(.setGain(identifier: application.identifier, gain: 0.4))
    route.onObservation?(
      AudioRouteObservation(
        key: route.key, phase: .accepted,
        cleanupFailure: AudioRouteFailure(
          stage: "update-cleanup", message: "Latched update cleanup")))
    runtime.holdUpdates = []
    runtime.releaseUpdates("A")
    await controller.waitForCurrentWork()
    #expect(route.updates.count == expectedUpdates)
    #expect(controller.lastFailure?.message == "Latched update cleanup")
    await controller.shutdown()
    #expect(route.retired && !route.rendering)
  }

  @Test(
    "A healthy multi-output commit cannot hide a retained owner's fault before explicit recovery",
    arguments: [AudioRouteFailureKind.nativeFailure, .cancelled])
  func retainedMultiOutputFailureSurvivesAnotherOutputCommit(kind: AudioRouteFailureKind)
    async throws
  {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let retained = try #require(runtime.handle("A"))
    #expect(retained.rendering)

    runtime.holdUpdates = ["A"]
    let nextUpdate = retained.updates.count + 1
    controller.perform(.setGain(identifier: application.identifier, gain: 0.5))
    try await runtime.wait("update:A:\(nextUpdate)")
    let updating = Task { @MainActor in
      runtime.emit("draining-retained-update")
      await controller.waitForCurrentWork()
    }
    try await runtime.wait("draining-retained-update")

    runtime.holdOperations["B"] = .commit
    controller.perform(
      .setRoute(identifier: application.identifier, mode: .multi, uids: ["A", "B"]))
    try await runtime.wait("deferred-commit:B")
    runtime.releaseUpdates("A")
    await updating.value

    let healthy = try #require(runtime.handle("B"))
    #expect(retained.rendering && retained.retirementAttempts == 0 && healthy.commits.isEmpty)
    let failure = AudioRouteFailure(
      kind: kind, stage: "render", code: -7301, message: "Retained A rendering failed")
    retained.rendering = false
    retained.onObservation?(
      AudioRouteObservation(key: retained.key, phase: .failed, failure: failure))
    #expect(controller.routeFailures["unit.player"] == failure && controller.lastFailure == failure)

    runtime.releaseOperation("B")
    await controller.waitForCurrentWork()
    #expect(healthy.rendering && !healthy.retired && healthy.retirementAttempts == 0)
    #expect(!retained.rendering && !retained.retired && retained.retirementAttempts == 0)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    #expect(controller.routeFailures["unit.player"] == failure && controller.lastFailure == failure)

    runtime.holdArmed = ["A"]
    controller.perform(
      .setRoute(identifier: application.identifier, mode: .multi, uids: ["A", "B"]))
    try await runtime.wait("started:A")
    let recovered = try #require(runtime.handle("A"))
    #expect(recovered !== retained && recovered.commits.isEmpty)
    #expect(controller.routeFailures["unit.player"] == failure)

    recovered.arm()
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A", "B"])
    #expect(recovered.rendering && retained.retired && runtime.requests.count == 3)
    #expect(runtime.handle("B") === healthy && healthy.rendering)
    #expect(controller.routeFailures["unit.player"] == nil && controller.lastFailure == nil)
    await controller.shutdown()
    #expect(recovered.retired && healthy.retired)
  }

  @Test("Peak observations clear on generation change, cleanup failure, and retiring")
  func routeObservationPeakFiltering() async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(
      .setRoute(identifier: application.identifier, mode: .multi, uids: ["A", "B"]))
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()

    let routeA = try #require(runtime.handle("A"))
    let routeB = try #require(runtime.handle("B"))
    routeA.onObservation?(
      AudioRouteObservation(key: routeA.key, phase: .firstApplied, peakLevel: 0.25))
    routeB.onObservation?(
      AudioRouteObservation(key: routeB.key, phase: .firstApplied, peakLevel: 0.75))
    #expect(controller.routeObservations[routeA.key]?.peakLevel == 0.25)
    #expect(controller.routeObservations[routeB.key]?.peakLevel == 0.75)

    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: application.identifier, processID: 101, processRevision: 2,
        displayName: "Player", bundleID: application.bundleID)
    ])
    await controller.waitForCurrentWork()
    let current = try #require(runtime.handle("A"))
    #expect(current.key.generation > routeA.key.generation)

    // Stale generation observation cannot revive peak on the replaced key.
    routeA.onObservation?(
      AudioRouteObservation(key: routeA.key, phase: .firstApplied, peakLevel: 0.95))
    current.onObservation?(
      AudioRouteObservation(
        key: current.key, phase: .firstApplied,
        cleanupFailure: AudioRouteFailure(stage: "unit-cleanup", message: "Cleanup failed"),
        peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    current.onObservation?(
      AudioRouteObservation(key: current.key, phase: .firstApplied, peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    current.onObservation?(
      AudioRouteObservation(key: current.key, phase: .retiring, peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    await controller.shutdown()
  }
}
