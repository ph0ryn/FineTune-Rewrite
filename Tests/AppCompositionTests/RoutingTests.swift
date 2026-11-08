import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@Suite("Routing profile-cache invalidation")
@MainActor
struct ProfileAvailabilityCacheTests {
  @Test("Removing a profile invalidates only that cached ID and permits a later replacement")
  func removesOnlyTheSelectedProfile() {
    let first = AutoEQProfile(
      id: "first", name: "First", source: .imported, preampDB: -3, filters: [])
    let other = AutoEQProfile(
      id: "other", name: "Other", source: .bundled, preampDB: -5, filters: [])
    let cache = AutoEQProfileCache(profiles: [first, other])
    cache.remove(id: first.id)
    #expect(cache.profile(for: first.id) == nil)
    #expect(cache.profile(for: other.id) == other)
    cache.remove(id: "absent")
    #expect(cache.profile(for: other.id) == other)
    cache.store(first)
    #expect(cache.profile(for: first.id) == first)
  }
}

@Suite("Synchronous shared audio commands")
@MainActor
struct CommonAudioCommandTests {
  @Test("Inactive URL/raw changes persist while UI editing alone clears mute")
  func inactiveCommandsAndMuteSemantics() {
    let (settings, directory) = routingSettingsFixture()
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let identifier = "unit.inactive"
    controller.perform(.setMuted(identifier: identifier, muted: true))
    controller.perform(.setGain(identifier: identifier, gain: 0.4))
    #expect(settings.getVolume(for: identifier) == 0.4)
    #expect(settings.getMute(for: identifier) == true)
    controller.perform(.editGain(identifier: identifier, gain: 0))
    #expect(settings.getVolume(for: identifier) == 0)
    #expect(settings.getMute(for: identifier) == false)
    controller.perform(.setBoost(identifier: identifier, boost: .x3))
    controller.perform(.setRoute(identifier: identifier, mode: .multi, uids: ["A", "B"]))
    controller.perform(.stepSlider(identifier: identifier, delta: 0.1))
    controller.perform(.setOutputDevice(identifier: identifier, uid: "unavailable"))
    #expect(settings.getVolume(for: identifier) == 0)
    #expect(settings.getDeviceRouting(for: identifier) != "unavailable")
    controller.perform(.resetGainAndMute(identifier: identifier))
    #expect(settings.getVolume(for: identifier) == 1)
    #expect(settings.getMute(for: identifier) == false)
    #expect(settings.getBoost(for: identifier) == .x3)
    #expect(settings.getDeviceSelectionMode(for: identifier) == .multi)
    #expect(settings.getSelectedDeviceUIDs(for: identifier) == ["A", "B"])
    settings.flushSync()
    let restored = SettingsManager(
      directory: directory, launchAtLoginService: RoutingLoginService())
    #expect(restored.getVolume(for: identifier) == 1)
    #expect(restored.getMute(for: identifier) == false)
    #expect(restored.getBoost(for: identifier) == .x3)
  }

  @Test("Consecutive snapshot edits apply synchronously without losing fields or capture wish")
  func consecutiveSettingsSnapshots() {
    let (settings, _) = routingSettingsFixture()
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
    controller.perform(.requestCaptureStart)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    var first = settings.appSettings
    first.setUnifiedLoudnessEnabled(true)
    controller.perform(.updateAppSettings(first))
    #expect(settings.appSettings.loudnessCompensationEnabled)
    var second = settings.appSettings
    second.defaultNewAppVolume = 0.2
    controller.perform(.updateAppSettings(second))
    #expect(settings.appSettings.loudnessCompensationEnabled)
    #expect(settings.appSettings.loudnessEqualizationEnabled)
    #expect(settings.appSettings.defaultNewAppVolume == 0.2)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    controller.perform(.stopCapture)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Popup Shift doubles the configured slider step, including pinned-inactive rows")
  func popupShiftDoublesConfiguredStep() {
    let (settings, _) = routingSettingsFixture()
    settings.setVolume(for: "unit.pinned", to: 0.25)
    settings.setMute(for: "unit.pinned", to: true)
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.perform(.stepVolume(identifier: "unit.pinned", isUp: true, shift: true))
    #expect(settings.getVolume(for: "unit.pinned") == 0.390625)
    #expect(settings.getMute(for: "unit.pinned") == false)
  }
}

@Suite("Controlled per-output routing", .timeLimit(.minutes(1)))
@MainActor
struct ControlledAudioRoutingTests {
  private let application = AudioApplicationDescriptor(
    identifier: "unit.player", processID: 101, processRevision: 1, displayName: "Player",
    bundleID: "unit.player")
  private let a = AudioOutputDescriptor(
    uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 0.25, volume: 0.6,
    isMuted: false)
  private let b = AudioOutputDescriptor(
    uid: "B", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 0.8,
    isMuted: false)

  @Test("Unarmed candidate retains old route; armed cannot commit before old retirement")
  func armedAndRetirementHandoff() async throws {
    let (settings, _) = routingSettingsFixture()
    settings.setVolume(for: application.identifier, to: 0.4)
    settings.setBoost(for: application.identifier, to: .x2)
    let runtime = RoutingProbeRuntime()
    runtime.holdArmed = ["B"]
    runtime.holdRetirement = ["A"]
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    #expect(runtime.requests.isEmpty)
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("started:B")
    let candidate = try #require(runtime.handle("B"))
    #expect(old.retirementAttempts == 0 && old.rendering)
    #expect(candidate.commits.isEmpty && !candidate.rendering)
    controller.perform(.setGain(identifier: application.identifier, gain: 0.3))
    controller.perform(.setMuted(identifier: application.identifier, muted: true))
    #expect(abs(try #require(old.levels.last).effectiveGain - 0.15) < 0.000_001)
    #expect(abs(try #require(candidate.levels.last).effectiveGain - 0.6) < 0.000_001)
    #expect(try #require(old.levels.last).isMuted)
    #expect(try #require(candidate.levels.last).isMuted)
    #expect(abs(try #require(old.levels.last).effectiveLoudnessVolume - 0.18) < 0.000_001)
    #expect(abs(try #require(candidate.levels.last).effectiveLoudnessVolume - 0.24) < 0.000_001)
    candidate.arm()
    await runtime.wait("retire:A")
    #expect(candidate.commits.isEmpty && !candidate.rendering)
    old.finishRetirement()
    await controller.waitForCurrentWork()
    let committed = try #require(candidate.commits.first)
    #expect(abs(committed.effectiveGain - 0.6) < 0.000_001 && committed.isMuted)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    #expect(runtime.requests.count == 2)
    await controller.shutdown()
    #expect(candidate.retired && settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Blocked processing coalesces latest full state while hot levels remain immediate")
  func coalescesFullStateWithoutLosingHotLevels() async throws {
    let (settings, _) = routingSettingsFixture()
    settings.setBoost(for: application.identifier, to: .x2)
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    await runtime.wait("update:A:\(nextUpdate)")
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
    "A cancelled old update neither creates a banner nor replaces the current candidate's failure",
    arguments: [false, true])
  func cancelledOldUpdatePreservesCurrentFailure(currentCandidateFails: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    runtime.holdUpdates = ["A"]
    let nextUpdate = old.updates.count + 1
    controller.perform(
      .setEQ(
        identifier: application.identifier,
        settings: EQSettings(bandGains: Array(repeating: 2, count: 10))))
    await runtime.wait("update:A:\(nextUpdate)")
    // Join only the existing update before adding a handoff that must remain pending.
    let updating = Task { @MainActor in
      runtime.emit("draining-old-update")
      await controller.waitForCurrentWork()
    }
    await runtime.wait("draining-old-update")
    runtime.holdArmed = ["B"]
    runtime.holdRetirement = ["A"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("started:B")
    let candidate = try #require(runtime.handle("B"))
    #expect(old.rendering && old.retirementAttempts == 0)
    candidate.arm()
    await runtime.wait("retire:A")
    #expect(old.cancelled && !old.retired && !old.rendering)
    #expect(candidate.commits.isEmpty && !candidate.rendering)
    let currentFailure: AudioRouteFailure? =
      currentCandidateFails
      ? AudioRouteFailure(stage: "process", message: "Current B processing failed") : nil
    if let currentFailure {
      candidate.onObservation?(
        AudioRouteObservation(key: candidate.key, phase: .failed, failure: currentFailure))
    }
    #expect(controller.lastFailure == currentFailure)
    runtime.releaseUpdates("A")
    await updating.value
    #expect(controller.lastFailure == currentFailure)
    #expect(!old.retired && candidate.commits.isEmpty)
    old.finishRetirement()
    await controller.waitForCurrentWork()
    #expect(old.retired && old.retirementAttempts == 1)
    #expect(
      controller.lastFailure == currentFailure && controller.captureRetryFailure == currentFailure)
    if currentCandidateFails {
      #expect(controller.routeObservations[candidate.key]?.failure == currentFailure)
      #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty)
      #expect(!candidate.rendering)
    } else {
      #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
      #expect(candidate.rendering && !candidate.retired)
    }
    await controller.shutdown()
    #expect(old.retired && candidate.retired && !candidate.rendering)
  }

  @Test(
    "Another app acquiring successfully cannot hide a still-silent active route's failure",
    arguments: [AudioRouteFailureKind.nativeFailure, .cancelled])
  func unrelatedAcquisitionPreservesActiveRouteFailure(kind: AudioRouteFailureKind) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let silentApplication = AudioApplicationDescriptor(
      identifier: "unit.silent", processID: 102, processRevision: 1, displayName: "Silent",
      bundleID: "unit.silent")
    let c = AudioOutputDescriptor(
      uid: "C", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([b, c], defaultUID: "B")
    controller.observeApplications([application, silentApplication])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let failed = try #require(
      runtime.handles.first { $0.key.appIdentifier == silentApplication.identifier })
    #expect(settings.isFollowingDefault(for: application.identifier))
    #expect(settings.isFollowingDefault(for: silentApplication.identifier))
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    #expect(controller.activeDeviceUIDs(for: silentApplication.identifier) == ["B"])
    #expect(failed.rendering && runtime.requests.count == 2)
    let failure = AudioRouteFailure(
      kind: kind, stage: "render", code: -5201, message: "Active B rendering failed")
    failed.rendering = false
    // A runtime observation must remain visible without an acquisition/receipt failure latch.
    failed.onObservation?(
      AudioRouteObservation(key: failed.key, phase: .failed, failure: failure))
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
    #expect(controller.captureRetryFailure == nil)
    #expect(controller.lastFailure == failure)
    runtime.holdUpdates = ["B"]
    runtime.holdRetirement = ["B"]
    controller.perform(
      .setRoute(identifier: silentApplication.identifier, mode: .single, uids: ["C"]))
    await runtime.wait("retire:\(silentApplication.identifier):B")
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
    "A late cancelled start or commit retained by successful retirement cannot veto a healthy replacement",
    arguments: RoutingDeferredOperation.allCases)
  func lateCancelledPrimaryDoesNotRejectRetirement(operation: RoutingDeferredOperation) async throws
  {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let c = AudioOutputDescriptor(
      uid: "C", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let original = try #require(runtime.handle("A"))
    runtime.holdOperations["B"] = operation
    runtime.holdRetirement = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("deferred-\(operation.rawValue):B")
    let late = try #require(runtime.handle("B"))
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    await runtime.wait("retire:B")
    let replacement = try #require(runtime.handle("C"))
    #expect(late.cancelled && !late.retired && replacement.commits.isEmpty)
    #expect(controller.routeObservations[late.key]?.failure == nil)
    runtime.releaseOperation("B")
    await runtime.wait("late-cancelled:B")
    // The new cancellation appears only after retirement began, then survives the quiescent ACK.
    late.finishRetirement()
    await controller.waitForCurrentWork()
    #expect(controller.routeObservations[late.key]?.phase == .retired)
    #expect(controller.routeObservations[late.key]?.failure?.kind == .cancelled)
    #expect(controller.lastFailure == nil && controller.captureRetryFailure == nil)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["C"])
    #expect(replacement.rendering && !replacement.retired)
    #expect(original.retired && late.retired && late.retirementAttempts == 1)
    await controller.shutdown()
    #expect(replacement.retired && !replacement.rendering)
  }

  @Test(
    "Superseded started IO retires even while its replacement has no source data",
    .timeLimit(.minutes(1)))
  func cancelledOwnerDoesNotWaitForIdleReplacement() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let c = AudioOutputDescriptor(
      uid: "C", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let original = try #require(runtime.handle("A"))
    runtime.holdOperations["B"] = .commit
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("deferred-commit:B")
    let superseded = try #require(runtime.handle("B"))
    #expect(original.retired && superseded.ioRunning)
    runtime.holdArmed = ["C"]
    runtime.holdRetirement = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    await runtime.wait("started:C")
    let replacement = try #require(runtime.handle("C"))
    await runtime.wait("retire:B")
    #expect(superseded.cancelled && !superseded.ioRunning && !superseded.retired)
    #expect(superseded.retirementAttempts == 1)
    runtime.releaseOperation("B")
    await runtime.wait("late-cancelled:B")
    #expect(superseded.cancellationsDuringRetirement == 0)
    superseded.finishRetirement()
    #expect(replacement.ioRunning && replacement.commits.isEmpty && !replacement.rendering)
    replacement.arm()
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["C"])
    #expect(controller.lastFailure == nil && replacement.rendering)
    await controller.shutdown()
    #expect(runtime.handles.allSatisfy { !$0.ioRunning && $0.retired })
  }

  @Test(
    "Early retirement failure is joined, not retried when an idle replacement later arms",
    .timeLimit(.minutes(1)))
  func earlyCancelledCleanupFailureDoesNotRetry() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let c = AudioOutputDescriptor(
      uid: "C", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    runtime.holdOperations["B"] = .commit
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("deferred-commit:B")
    let superseded = try #require(runtime.handle("B"))
    let failure = AudioRouteFailure(stage: "retire", message: "Cancelled IO cleanup failed")
    runtime.holdArmed = ["C"]
    runtime.holdRetirement = ["B"]
    runtime.retirementCallbackFailure = failure
    runtime.retirementCallbackUsesCleanup = true
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    await runtime.wait("started:C")
    runtime.releaseOperation("B")
    await runtime.wait("late-cancelled:B")
    await runtime.wait("retire:B")
    #expect(superseded.retirementAttempts == 1)
    runtime.holdRetirement = []
    runtime.retirementCallbackFailure = nil
    let replacement = try #require(runtime.handle("C"))
    replacement.arm()
    await controller.waitForCurrentWork()
    #expect(superseded.retirementAttempts == 1 && !superseded.retired)
    #expect(replacement.commits.isEmpty && controller.lastFailure == failure)
    // A real later retired notification may release ownership, but cannot erase its cleanup failure.
    superseded.finishRetirement(cleanupFailure: failure)
    await controller.shutdown()
    #expect(superseded.retirementAttempts == 1 && controller.lastFailure == failure)
  }

  @Test(
    "Explicit capture retry reattempts failed cleanup without hiding repeated errors",
    arguments: [false, true])
  func explicitRetryReattemptsFailedRetirement(recovers: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let cleanup = AudioRouteFailure(
      stage: "stop", code: 560_227_702, message: "Native device cleanup failed")
    old.retirementError = cleanup
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 1 && old.ioRunning && !old.retired)
    #expect(controller.unresolvedRetirementFailures[old.key] == cleanup)
    #expect(runtime.handle("B")?.commits.isEmpty == true)
    // Passive observation is not permission to retry a failed resource operation.
    controller.observeOutputs([a, b], defaultUID: "A")
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 1)
    if recovers { old.retirementError = nil }
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 2)
    let candidate = try #require(runtime.handle("B"))
    if recovers {
      #expect(old.retired && !old.ioRunning && candidate.rendering)
      #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
      #expect(controller.lastFailure == nil && controller.captureRetryFailure == nil)
      #expect(controller.unresolvedRetirementFailures.isEmpty)
      #expect(controller.routeObservations[old.key]?.cleanupFailure == cleanup)
    } else {
      #expect(!old.retired && old.ioRunning && candidate.commits.isEmpty)
      #expect(controller.lastFailure == cleanup)
      #expect(controller.unresolvedRetirementFailures[old.key] == cleanup)
      old.finishRetirement(cleanupFailure: cleanup)
    }
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getDeviceRouting(for: application.identifier) == "B")
    await controller.shutdown()
    #expect(runtime.handles.allSatisfy { $0.retired && !$0.ioRunning })
  }

  @Test(
    "Repeated explicit retry joins PENDING cleanup and honors its current ACK",
    arguments: [false, true])
  func repeatedExplicitRetryJoinsPendingCleanup(ackFails: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let failure = AudioRouteFailure(stage: "stop", message: "Historical cleanup failure")
    old.retirementError = failure
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await controller.waitForCurrentWork()
    old.retirementError = nil
    runtime.holdRetirement = ["A"]
    controller.perform(.requestCaptureStart)
    controller.perform(.requestCaptureStart)
    await runtime.wait("retire:A:2")
    #expect(old.retirementAttempts == 2 && !old.retired)
    #expect(controller.unresolvedRetirementFailures[old.key] == failure)
    #expect(runtime.handles.filter { $0.key.deviceUID == "B" }.allSatisfy { $0.commits.isEmpty })
    old.finishRetirement(cleanupFailure: ackFails ? failure : nil)
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 2 && old.retired)
    if ackFails {
      #expect(runtime.handle("B")?.commits.isEmpty == true && controller.lastFailure == failure)
    } else {
      #expect(runtime.handle("B")?.rendering == true && controller.lastFailure == nil)
    }
    #expect(controller.unresolvedRetirementFailures.isEmpty)
    #expect(controller.routeObservations[old.key]?.cleanupFailure == failure)
    await controller.shutdown()
  }

  @Test(
    "A retry's early retired ACK cannot bypass its unsettled receipt", .timeLimit(.minutes(1)),
    arguments: [false, true])
  func retryRetirementReceiptGatesNewPlan(receiptFails: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let failure = AudioRouteFailure(stage: "stop", message: "Same cleanup failure")
    old.retirementError = failure
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await controller.waitForCurrentWork()
    old.retirementError = nil
    runtime.holdRetirementReceipt = ["A"]
    controller.perform(.requestCaptureStart)
    await runtime.wait("retirement-receipt:A")
    #expect(old.retired && controller.unresolvedRetirementFailures.isEmpty)
    // This new plan starts after ACK removed the native owner, but before the call's receipt.
    let nextPrepare = runtime.requests.count + 1
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["A"]))
    await runtime.wait("prepare:A:\(nextPrepare)")
    runtime.releaseRetirementReceipt("A", result: receiptFails ? .failed(failure) : .retired)
    await controller.waitForCurrentWork()
    #expect(!runtime.committedBeforeRetirementReceipt)
    let latest = try #require(runtime.handle("A"))
    if receiptFails {
      #expect(latest.commits.isEmpty && controller.lastFailure == failure)
    } else {
      #expect(latest.rendering && controller.lastFailure == nil)
    }
    #expect(old.retirementAttempts == 2)
    await controller.shutdown()
  }

  @Test("Late cancelled preparation only retires its own owner, not the newer route")
  func stalePreparationCannotActivate() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    runtime.holdPreparation = ["B"]
    let c = AudioOutputDescriptor(
      uid: "C", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
      isMuted: false)
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("prepare:B")
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    await runtime.wait("commit:C")
    runtime.releasePreparation("B")
    await controller.waitForCurrentWork()
    await runtime.wait("retired:B")
    let stale = try #require(runtime.handle("B"))
    let current = try #require(runtime.handle("C"))
    #expect(stale.cancelled && stale.retired && stale.commits.isEmpty)
    #expect(current.rendering && !current.retired)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["C"])
    #expect(settings.getSelectedDeviceUIDs(for: application.identifier) == ["C"])
    controller.perform(.stopCapture)
    await controller.shutdown()
    #expect(current.retired && !settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test(
    "Multi output uses independent UID gain/profile; missing cache data keeps the saved selection")
  func independentUIDProcessingAndProfileRemoval() async throws {
    let (settings, _) = routingSettingsFixture()
    settings.setVolume(for: application.identifier, to: 0.3)
    settings.setBoost(for: application.identifier, to: .x3)
    settings.setDeviceRouting(for: application.identifier, deviceUID: "A")
    settings.setDeviceSelectionMode(for: application.identifier, to: .multi)
    settings.setSelectedDeviceUIDs(for: application.identifier, to: ["A", "B"])
    let first = AutoEQProfile(id: "pa", name: "A", source: .imported, preampDB: -3, filters: [])
    let second = AutoEQProfile(id: "pb", name: "B", source: .imported, preampDB: -6, filters: [])
    let cache = AutoEQProfileCache(profiles: [first, second])
    settings.setAutoEQSelection(for: "A", to: AutoEQSelection(profileID: "pa", isEnabled: true))
    settings.setAutoEQSelection(for: "B", to: AutoEQSelection(profileID: "pb", isEnabled: true))
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { cache.profile(for: $0) },
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
    cache.remove(id: "pa")
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

  @Test("Typed known denial blocks reconnect work until a fresh explicit retry")
  func knownDenialDoesNotRetryAutomatically() async {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
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
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    await runtime.wait("started:A")
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
    "A binding failure remains diagnostic history, not a failure of successful old-route retirement",
    arguments: [false, true], [false, true])
  func bindingChangeRecoversAfterOldRouteRetires(pending: Bool, switchOutput: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let failure = AudioRouteFailure(
      kind: .bindingChanged, stage: "certifyFormat", code: -5101, message: "Old binding changed")
    if pending { runtime.holdRetirement = ["A"] }
    old.rendering = false
    old.onObservation?(AudioRouteObservation(key: old.key, phase: .failed, failure: failure))
    let target = switchOutput ? "B" : "A"
    if switchOutput {
      controller.perform(
        .setRoute(identifier: application.identifier, mode: .single, uids: [target]))
    }
    await runtime.wait("retire:A")
    let replacement = try #require(runtime.handle(target))
    #expect(replacement.key != old.key)
    if pending {
      #expect(replacement.commits.isEmpty)
      old.finishRetirement(failure: failure)
      runtime.holdRetirement = []
    }
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(old.retired && old.retirementAttempts == 1)
    #expect(controller.routeObservations[old.key]?.failure == failure)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == [target])
    #expect(replacement.rendering && !replacement.retired)
    #expect(controller.captureRetryFailure == nil && controller.lastFailure == nil)
    await controller.shutdown()
  }

  @Test(
    "A failed old route still rejects handoff on a new retirement or cleanup error",
    arguments: [false, true])
  func oldRouteFailureDoesNotHideRetirementError(cleanupChannel: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    old.onObservation?(
      AudioRouteObservation(
        key: old.key, phase: .failed,
        failure: AudioRouteFailure(stage: "process", message: "Historical processing error")))
    let cleanup = AudioRouteFailure(stage: "retire-callback", message: "New retirement failure")
    runtime.holdRetirement = ["A"]
    runtime.retirementCallbackFailure = cleanup
    runtime.retirementCallbackUsesCleanup = cleanupChannel
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))
    old.finishRetirement()
    await controller.waitForCurrentWork()
    #expect(candidate.commits.isEmpty && !candidate.rendering)
    #expect(controller.lastFailure == cleanup)
    await controller.shutdown()
  }

  @Test(
    "Selecting an output retries failed following routes, not pinned routes or input selections")
  func defaultOutputSelectionRetriesFailedFollowingRoutes() async throws {
    let (settings, _) = routingSettingsFixture()
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1, displayName: "Pinned",
      bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "A")
    let runtime = RoutingProbeRuntime()
    let failure = AudioRouteFailure(
      kind: .unsupported, stage: "certifyFormat", code: -5101, message: "Initial format rejected")
    runtime.prepareFailure = failure
    let writer = RoutingDefaultWriter()
    writer.failure = AudioRouteFailure(stage: "output-write", message: "Write rejected")
    let policy = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { try writer.write($0) })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: [])
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { policy.routingDecision() },
      deviceCommand: { command in
        if case .setDefaultDevice(.output, let uid) = command {
          try policy.selectDefaultOutput(uid: uid)
        }
      })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application, pinned])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2 && controller.captureRetryFailure == failure)
    let session = controller.captureIntent
    runtime.prepareFailure = nil
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.perform(.setDefaultDevice(scope: .input, uid: "microphone"))
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2 && controller.captureRetryFailure == failure)
    controller.perform(.setDefaultDevice(scope: .output, uid: "B"))
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2 && controller.commandFailure?.stage == "output-write")
    writer.failure = nil
    controller.perform(.setDefaultDevice(scope: .output, uid: "B"))
    await controller.waitForCurrentWork()
    // Policy approval precedes the physical default's asynchronous observation.
    #expect(controller.defaultOutputUID == "A" && policy.intendedDefaultUID == "B")
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    #expect(runtime.requests.count == 3 && runtime.requests.last?.key.deviceUID == "B")
    #expect(controller.activeDeviceUIDs(for: pinned.identifier).isEmpty)
    #expect(runtime.requests.filter { $0.key.appIdentifier == pinned.identifier }.count == 1)
    #expect(settings.getDeviceRouting(for: pinned.identifier) == "A")
    #expect(settings.isFollowingDefault(for: application.identifier))
    #expect(controller.captureIntent == session && !controller.knownPermissionDenied)
    controller.observeOutputs([a, b], defaultUID: "B")
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 3)
    await controller.shutdown()
  }

  @Test("Stop shares pending retirement and shutdown collects both owners exactly once")
  func stopDuringPendingRetirementSharesOwner() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    runtime.holdRetirement = ["A"]
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))
    controller.perform(.stopCapture)
    // No second same-token wait: finish in this actor turn, then inspect every collected request.
    old.finishRetirement()
    await controller.shutdown()
    #expect(old.retirementAttempts == 1)
    #expect(candidate.retirementAttempts == 1)
    #expect(old.retired && candidate.retired && !old.rendering && !candidate.rendering)
    #expect(candidate.commits.isEmpty && controller.captureIntent == .none)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test(
    "A failed same target retries through route/start while retaining usable multi outputs",
    arguments: [DeviceSelectionMode.single, .multi], [false, true])
  func failedSameTargetCanRetry(mode: DeviceSelectionMode, retryStart: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let original = try #require(runtime.handle("A"))
    runtime.prepareFailure = AudioRouteFailure(stage: "prepare", message: "Transient unit failure")
    let desired: Set<String> = mode == .single ? ["B"] : ["A", "B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: mode, uids: desired))
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    #expect(!controller.knownPermissionDenied && runtime.requests.count == 2)
    runtime.prepareFailure = nil
    if retryStart {
      controller.perform(.requestCaptureStart)
    } else {
      controller.perform(.setRoute(identifier: application.identifier, mode: mode, uids: desired))
    }
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == desired)
    #expect(runtime.requests.count == 3)
    #expect(original.retirementAttempts == (mode == .single ? 1 : 0))
    #expect(settings.getSelectedDeviceUIDs(for: application.identifier) == desired)
    await controller.shutdown()
  }

  @Test(
    "Failed observation preserves last-good owner; successful empty retires without erasing wishes",
    arguments: [false, true])
  func failureIsNotSuccessfulEmpty(applicationsEntry: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    await runtime.wait("retired:A")
    #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty && route.retired)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getDeviceRouting(for: application.identifier) == "A")
    await controller.shutdown()
  }

  @Test(
    "An applied callback survives a delayed older receipt and hot levels never invent full applied")
  func callbackBeforeOldReceiptPreservesApplied() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    await runtime.wait("update:A:\(nextUpdate)")
    let applied = try #require(route.updates.last).revision
    route.nextUpdateReceipt = AudioRouteObservation(
      key: route.key, phase: .accepted,
      acceptedRevision: previous, appliedRevision: previous)
    route.onObservation?(
      AudioRouteObservation(
        key: route.key, phase: .firstApplied,
        acceptedRevision: applied, appliedRevision: applied))
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

  @Test("Stop waits for a held preparation and retires only its late owner without committing")
  func stopCollectsLatePreparedOwner() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    runtime.holdPreparation = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("prepare:B")
    let late = try #require(runtime.handle("B"))
    controller.perform(.stopCapture)
    var shutdownComplete = false
    let stopping = Task { @MainActor in
      await controller.shutdown()
      shutdownComplete = true
    }
    await runtime.wait("retired:A")
    #expect(!shutdownComplete && !late.retired && old.retirementAttempts == 1)
    runtime.releasePreparation("B")
    await stopping.value
    #expect(shutdownComplete && late.commits.isEmpty && late.cancelled && late.retired)
    #expect(old.retirementAttempts == 1 && late.retirementAttempts == 1)
    #expect(!old.rendering && !late.rendering && !settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getDeviceRouting(for: application.identifier) == "B")
  }

  @Test(
    "Retirement errors survive callback/receipt ordering and successful quiescence acknowledgements",
    arguments: [false, true], RoutingRetirementFailureOrder.allCases)
  func errorBeforePendingRetirementRejectsCommit(
    cleanupChannel: Bool, order: RoutingRetirementFailureOrder
  ) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    runtime.holdRetirement = ["A"]
    runtime.retirementCallbackFailure = AudioRouteFailure(
      stage: "retire-callback", message: "Callback retirement failure")
    runtime.retirementCallbackUsesCleanup = cleanupChannel
    runtime.retirementFailureOrder = order
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))
    // Bound the Red: quiescence always arrives, but never turns an operation error into success.
    if order == .errorWithRetiredAfterPending {
      old.finishRetirement(
        failure: cleanupChannel ? nil : runtime.retirementCallbackFailure,
        cleanupFailure: cleanupChannel ? runtime.retirementCallbackFailure : nil)
    } else if !old.retired {
      old.finishRetirement()
    }
    await controller.waitForCurrentWork()
    #expect(candidate.commits.isEmpty)
    #expect(controller.lastFailure?.message == "Callback retirement failure")
    await controller.shutdown()
    #expect(old.retired && candidate.retired && !candidate.rendering)
  }

  @Test(
    "An armed cleanup error rejects commit whether callback or receipt arrives first",
    arguments: [false, true])
  func cleanupErrorBeforeArmedReceiptRejectsCommit(afterReceipt: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    let failure = AudioRouteFailure(
      stage: "start-cleanup", message: "Callback start cleanup failure")
    if afterReceipt { runtime.holdArmed = ["B"] } else { runtime.startCleanupFailure = failure }
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    await runtime.wait("started:B")
    let candidate = try #require(runtime.handle("B"))
    if afterReceipt {
      candidate.onObservation?(
        AudioRouteObservation(key: candidate.key, phase: .armed, cleanupFailure: failure))
    }
    await controller.waitForCurrentWork()
    #expect(candidate.commits.isEmpty && old.retirementAttempts == 0)
    #expect(controller.lastFailure?.message == "Callback start cleanup failure")
    await controller.shutdown()
    #expect(candidate.retired && old.retired)
  }

  @Test("A cleanup callback during initial commit is not erased by its later successful receipt")
  func commitReceiptCannotEraseLatchedError() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    runtime.commitCleanupFailure = AudioRouteFailure(
      stage: "commit-cleanup", message: "Latched commit cleanup")
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    await runtime.wait("update:A:\(expectedUpdates)")
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
    "A late default candidate cannot commit after an approved routing target changes",
    arguments: [false, true])
  func pendingDefaultCandidateRechecksApprovedTarget(notifySnapshot: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let decision = RoutingDecisionProbe()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { decision.value })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    runtime.holdPreparation = ["B"]
    controller.observeOutputs([a, b], defaultUID: "B")
    await runtime.wait("prepare:B")
    let candidate = try #require(runtime.handle("B"))
    decision.value = .routeToApprovedUID("A")
    if notifySnapshot { controller.observeOutputs([a, b], defaultUID: "B") }
    runtime.releasePreparation("B")
    await controller.waitForCurrentWork()
    #expect(candidate.commits.isEmpty && candidate.cancelled && !candidate.rendering)
    #expect(
      old.rendering && !old.retired
        && controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    #expect(controller.defaultOutputUID == "B" && controller.outputObservationFailure == nil)
    decision.value = .followObserved
    controller.observeOutputs([a, b], defaultUID: "B")
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"] && old.retired)
    #expect(runtime.requests.filter { $0.key.deviceUID == "B" }.count == 2)
    await controller.shutdown()
    #expect(candidate.retired)
  }

  @Test("An accepted default obsoletes a pending old target before asynchronous snapshot delivery")
  func acceptedDefaultPrecedesObservedSnapshot() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let actual = RoutingDecisionProbe()
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { uid in
        writes.append(uid)
        actual.actualUID = uid
      }, sleep: { try await clock.sleep($0) })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: [])
    runtime.holdPreparation = ["A"]
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { policy.routingDecision() })
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await runtime.wait("prepare:A")
    let pending = try #require(runtime.handle("A"))
    try policy.selectDefaultOutput(uid: "B")
    #expect(writes == ["B"] && policy.intendedDefaultUID == "B" && actual.actualUID == "B")
    #expect(controller.defaultOutputUID == "A")
    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()
    #expect(pending.commits.isEmpty && pending.cancelled && !pending.rendering)
    #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty)
    #expect(
      settings.isFollowingDefault(for: application.identifier)
        && settings.appSettings.explicitUserCaptureEnabled)
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: [])
    controller.observeOutputs([a, b], defaultUID: "B")
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["B"])
    await controller.shutdown()
    #expect(pending.retired)
  }

  @Test("A new following app routes to the approved UID after physical restoration fails")
  func newFollowingAppUsesApprovedDefault() async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let high = AudioOutputDescriptor(
      uid: "High", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1,
      volume: 1, isMuted: false)
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1, displayName: "Pinned",
      bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "High")
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { uid in
        writes.append(uid)
        throw AudioRouteFailure(stage: "default-write", message: "Restore rejected")
      })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["High", "A"], defaultUID: "A", bluetoothUIDs: [])
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { policy.routingDecision() }
    )
    controller.observeOutputs([high, a], defaultUID: "A")
    controller.observeApplications([pinned])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let pinnedOwner = try #require(runtime.handle("High"))
    #expect(runtime.handle("A") == nil)
    policy.observe(availableUIDs: ["High", "A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    controller.observeOutputs([high, a, b], defaultUID: "B")
    controller.observeApplications([pinned, application])
    await controller.waitForCurrentWork()
    #expect(writes == ["A"] && policy.lastFailure?.message == "Restore rejected")
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    #expect(runtime.requests.filter { $0.key.deviceUID == "A" }.count == 1)
    #expect(runtime.requests.allSatisfy { $0.key.deviceUID != "B" })
    #expect(pinnedOwner.rendering && !pinnedOwner.retired)
    #expect(controller.defaultOutputUID == "B" && policy.observedDefaultUID == "B")
    #expect(
      settings.isFollowingDefault(for: application.identifier)
        && settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test(
    "An unavailable approved default never silently falls back to the rejected actual default",
    arguments: [false, true])
  func unavailableApprovedDefaultIsExplicit(hadActive: Bool) async throws {
    let (settings, _) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .routeToApprovedUID("A") })
    controller.observeApplications([application])
    if hadActive {
      controller.observeOutputs([a, b], defaultUID: "A")
      controller.perform(.requestCaptureStart)
      await controller.waitForCurrentWork()
      #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    }
    controller.observeOutputs([b], defaultUID: "B")
    if !hadActive { controller.perform(.requestCaptureStart) }
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == (hadActive ? 1 : 0))
    #expect(controller.activeDeviceUIDs(for: application.identifier).isEmpty)
    #expect(controller.lastFailure?.kind == .unavailable)
    #expect(controller.defaultOutputUID == "B" && controller.outputs == [b])
    #expect(
      controller.outputObservationFailure == nil
        && settings.isFollowingDefault(for: application.identifier))
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    if let old = runtime.handle("A") { #expect(old.cancelled && !old.rendering) }
    await controller.shutdown()
    if let old = runtime.handle("A") { #expect(old.retired) }
  }

  @Test(
    "Confirmed reset-all synchronously clears wishes and cached active state then retires native owners"
  )
  func resetAllUsesSameControllerAndStore() async throws {
    let (settings, directory) = routingSettingsFixture()
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
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
    settings.setPreferredInputDeviceUID("desired-input")
    settings.setLockedInputDeviceUID("current-input")
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
    #expect(settings.preferredInputDeviceUID == nil && settings.lockedInputDeviceUID == nil)
    #expect(
      controller.captureIntent == .none && !settings.appSettings.explicitUserCaptureEnabled
        && owner.cancelled)
    await controller.shutdown()
    #expect(owner.retired && owner.retirementAttempts == 1 && runtime.requests.count == 1)
    settings.flushSync()
    let reloaded = SettingsManager(
      directory: directory, launchAtLoginService: RoutingLoginService())
    #expect(reloaded.getVolume(for: application.identifier) == nil)
    #expect(
      reloaded.getBoost(for: application.identifier) == nil
        && reloaded.getDeviceRouting(for: application.identifier) == nil)
    #expect(
      !reloaded.appSettings.explicitUserCaptureEnabled && reloaded.preferredInputDeviceUID == nil)
  }
}

@MainActor
private final class RoutingDefaultWriter {
  var failure: AudioRouteFailure?
  func write(_ uid: String) throws {
    if let failure { throw failure }
  }
}

@MainActor
private final class RoutingDecisionProbe {
  var value: ControlDefaultOutputRoutingDecision = .followObserved
  var actualUID: String? = "A"
}

enum RoutingRetirementFailureOrder: CaseIterable, Sendable {
  case errorBeforePending, errorAndRetiredBeforePending, errorBeforeRetiredResult,
    errorWithRetiredAfterPending
}

enum RoutingDeferredOperation: String, CaseIterable, Sendable {
  case start, commit
}

@MainActor
final class RoutingProbeRuntime: AudioRoutingRuntime {
  var requests: [AudioRouteRequest] = []
  var handles: [RoutingProbeRoute] = []
  var holdPreparation: Set<String> = []
  var holdArmed: Set<String> = []
  var holdRetirement: Set<String> = []
  var holdRetirementReceipt: Set<String> = []
  var committedBeforeRetirementReceipt = false
  private var retirementReceipts: [String: CheckedContinuation<AudioRetirementResult, Never>] = [:]
  var holdUpdates: Set<String> = []
  var holdOperations: [String: RoutingDeferredOperation] = [:]
  var prepareFailure: AudioRouteFailure?
  var retirementCallbackFailure: AudioRouteFailure?
  var retirementCallbackUsesCleanup = false
  var retirementFailureOrder: RoutingRetirementFailureOrder = .errorBeforePending
  var startCleanupFailure: AudioRouteFailure?
  var commitCleanupFailure: AudioRouteFailure?
  private var occurred: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var preparationGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var updateGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var operationGates: [String: CheckedContinuation<Void, Never>] = [:]
  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    requests.append(request)
    let route = RoutingProbeRoute(key: request.key, runtime: self)
    handles.append(route)
    emit("prepare:\(request.key.deviceUID)")
    emit("prepare:\(request.key.deviceUID):\(requests.count)")
    if holdPreparation.contains(request.key.deviceUID) {
      await withCheckedContinuation { preparationGates[request.key.deviceUID] = $0 }
    }
    if let prepareFailure { throw prepareFailure }
    return route
  }
  func waitForRetirementReceipt(_ uid: String) async -> AudioRetirementResult {
    await withCheckedContinuation {
      retirementReceipts[uid] = $0
      emit("retirement-receipt:\(uid)")
    }
  }
  func releaseRetirementReceipt(_ uid: String, result: AudioRetirementResult) {
    holdRetirementReceipt.remove(uid)
    retirementReceipts.removeValue(forKey: uid)?.resume(returning: result)
  }
  func recordCommit() {
    if !retirementReceipts.isEmpty { committedBeforeRetirementReceipt = true }
  }
  func handle(_ uid: String) -> RoutingProbeRoute? { handles.last { $0.key.deviceUID == uid } }
  func emit(_ name: String) {
    occurred.insert(name)
    for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.resume() }
  }
  func wait(_ name: String) async {
    if occurred.contains(name) { return }
    await withCheckedContinuation { waiters[name, default: []].append($0) }
  }
  func releasePreparation(_ uid: String) {
    holdPreparation.remove(uid)
    preparationGates.removeValue(forKey: uid)?.resume()
  }
  func suspendUpdate(_ uid: String) async {
    if holdUpdates.contains(uid) { await withCheckedContinuation { updateGates[uid] = $0 } }
  }
  func releaseUpdates(_ uid: String) {
    holdUpdates.remove(uid)
    updateGates.removeValue(forKey: uid)?.resume()
  }
  func suspendOperation(_ operation: RoutingDeferredOperation, uid: String) async {
    if holdOperations[uid] == operation {
      emit("deferred-\(operation.rawValue):\(uid)")
      await withCheckedContinuation { operationGates[uid] = $0 }
    }
  }
  func releaseOperation(_ uid: String) {
    holdOperations[uid] = nil
    operationGates.removeValue(forKey: uid)?.resume()
  }
}

@MainActor
final class RoutingProbeRoute: PreparedAudioRoute {
  let key: AudioRouteKey
  unowned let runtime: RoutingProbeRuntime
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  var commits: [AudioOutputState] = []
  var updates: [AudioOutputState] = []
  var nextUpdateReceipt: AudioRouteObservation?
  var levels: [AudioOutputLevels] = []
  var rendering = false
  // OS IO/tap muting survives closing render admission; only retirement actually stops it.
  var ioRunning = false
  var retired = false
  var cancelled = false
  var retirementAttempts = 0
  var retirementError: AudioRouteFailure?
  var cancellationsDuringRetirement = 0
  private var primaryFailure: AudioRouteFailure?
  init(key: AudioRouteKey, runtime: RoutingProbeRuntime) {
    self.key = key
    self.runtime = runtime
  }
  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    try checkAdmission()
    await runtime.suspendOperation(.start, uid: key.deviceUID)
    try checkAdmission(latchPrimary: true)
    if let failure = runtime.startCleanupFailure {
      onObservation?(AudioRouteObservation(key: key, phase: .started, cleanupFailure: failure))
    }
    ioRunning = true
    runtime.emit("started:\(key.deviceUID)")
    return AudioRouteObservation(
      key: key, phase: runtime.holdArmed.contains(key.deviceUID) ? .started : .armed,
      acceptedRevision: state.revision)
  }
  func arm() { onObservation?(AudioRouteObservation(key: key, phase: .armed)) }
  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    try checkAdmission()
    await runtime.suspendOperation(.commit, uid: key.deviceUID)
    try checkAdmission(latchPrimary: true)
    runtime.recordCommit()
    commits.append(state)
    ioRunning = true
    rendering = true
    if let failure = runtime.commitCleanupFailure {
      onObservation?(AudioRouteObservation(key: key, phase: .committed, cleanupFailure: failure))
    }
    runtime.emit("commit:\(key.deviceUID)")
    return AudioRouteObservation(key: key, phase: .committed, acceptedRevision: state.revision)
  }
  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    updates.append(state)
    runtime.emit("update:\(key.deviceUID):\(updates.count)")
    await runtime.suspendUpdate(key.deviceUID)
    if let receipt = nextUpdateReceipt {
      nextUpdateReceipt = nil
      return receipt
    }
    // Match the native adapter's post-await admission check without changing injected receipts.
    try checkAdmission()
    return AudioRouteObservation(key: key, phase: .accepted, acceptedRevision: state.revision)
  }
  private func checkAdmission(latchPrimary: Bool = false) throws {
    guard !cancelled && !retired else {
      let failure = AudioRouteFailure(
        kind: .cancelled, stage: "native", message: "The audio route was cancelled.")
      if latchPrimary {
        primaryFailure = failure
        runtime.emit("late-cancelled:\(key.deviceUID)")
      }
      throw failure
    }
  }
  func requestLevels(_ levels: AudioOutputLevels) { self.levels.append(levels) }
  func cancel() {
    // The production adapter's admission cancellation stops its current observation monitor.
    // Control must not repeat it after retirement has installed the PENDING progress monitor.
    if retirementAttempts > 0 && !retired { cancellationsDuringRetirement += 1 }
    cancelled = true
    rendering = false
  }
  func retire() async -> AudioRetirementResult {
    cancel()
    retirementAttempts += 1
    runtime.emit("retire:\(key.deviceUID):\(retirementAttempts)")
    if let error = retirementError {
      onObservation?(AudioRouteObservation(key: key, phase: .failed, cleanupFailure: error))
      return .failed(error)
    }
    ioRunning = false
    if runtime.holdRetirementReceipt.contains(key.deviceUID) {
      finishRetirement()
      return await runtime.waitForRetirementReceipt(key.deviceUID)
    }
    runtime.emit("retire:\(key.deviceUID)")
    runtime.emit("retire:\(key.appIdentifier):\(key.deviceUID)")
    if runtime.holdRetirement.contains(key.deviceUID) && !retired {
      let earlyError = runtime.retirementFailureOrder != .errorWithRetiredAfterPending
      onObservation?(
        AudioRouteObservation(
          key: key, phase: .retiring,
          failure: earlyError && !runtime.retirementCallbackUsesCleanup
            ? runtime.retirementCallbackFailure : nil,
          cleanupFailure: earlyError && runtime.retirementCallbackUsesCleanup
            ? runtime.retirementCallbackFailure : nil))
      if runtime.retirementCallbackFailure != nil {
        if runtime.retirementFailureOrder == .errorAndRetiredBeforePending { finishRetirement() }
        if runtime.retirementFailureOrder == .errorBeforeRetiredResult {
          finishRetirement()
          return .retired
        }
      }
      return .pending
    }
    finishRetirement()
    return .retired
  }
  func finishRetirement(failure: AudioRouteFailure? = nil, cleanupFailure: AudioRouteFailure? = nil)
  {
    retired = true
    rendering = false
    ioRunning = false
    onObservation?(
      AudioRouteObservation(
        key: key, phase: .retired, failure: failure ?? primaryFailure,
        cleanupFailure: cleanupFailure))
    runtime.emit("retired:\(key.deviceUID)")
  }
}

@MainActor
private func routingSettingsFixture() -> (SettingsManager, URL) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "CommonAudio-\(UUID().uuidString)", isDirectory: true)
  return (
    SettingsManager(directory: directory, launchAtLoginService: RoutingLoginService()), directory
  )
}

@MainActor
private final class RoutingLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
