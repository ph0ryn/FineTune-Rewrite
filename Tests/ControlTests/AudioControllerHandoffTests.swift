import FineTuneControl
import FineTuneDomain
import Testing

@Suite(
  "Control: AudioController route handoff, cancellation, and retirement", .timeLimit(.minutes(1)))
@MainActor
struct AudioControllerHandoffTests {
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
    runtime: ControlledRoutingRuntime = ControlledRoutingRuntime()
  ) -> (AudioController, InMemoryControlSettingsStore, ControlledRoutingRuntime) {
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    return (controller, settings, runtime)
  }

  @Test("Unarmed candidate retains old route; armed cannot commit before old retirement")
  func armedAndRetirementHandoff() async throws {
    let (controller, settings, runtime) = makeController()
    settings.setVolume(for: application.identifier, to: 0.4)
    settings.setBoost(for: application.identifier, to: .x2)
    runtime.holdArmed = ["B"]
    runtime.holdRetirement = ["A"]

    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    #expect(runtime.requests.isEmpty)
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])

    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("started:B")
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
    try await runtime.wait("retire:A")
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

  @Test(
    "A cancelled old update neither creates a banner nor replaces the current candidate's failure",
    arguments: [false, true])
  func cancelledOldUpdatePreservesCurrentFailure(currentCandidateFails: Bool) async throws {
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("update:A:\(nextUpdate)")

    let updating = Task { @MainActor in
      runtime.emit("draining-old-update")
      await controller.waitForCurrentWork()
    }
    try await runtime.wait("draining-old-update")

    runtime.holdArmed = ["B"]
    runtime.holdRetirement = ["A"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("started:B")
    let candidate = try #require(runtime.handle("B"))
    #expect(old.rendering && old.retirementAttempts == 0)

    candidate.arm()
    try await runtime.wait("retire:A")
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
    "A late cancelled start or commit retained by successful retirement cannot veto a healthy replacement",
    arguments: ControlDeferredOperation.allCases)
  func lateCancelledPrimaryDoesNotRejectRetirement(operation: ControlDeferredOperation) async throws
  {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let original = try #require(runtime.handle("A"))

    runtime.holdOperations["B"] = operation
    runtime.holdRetirement = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("deferred-\(operation.rawValue):B")
    let late = try #require(runtime.handle("B"))

    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    try await runtime.wait("retire:B")
    let replacement = try #require(runtime.handle("C"))
    #expect(late.cancelled && !late.retired && replacement.commits.isEmpty)
    #expect(controller.routeObservations[late.key]?.failure == nil)

    runtime.releaseOperation("B")
    try await runtime.wait("late-cancelled:B")
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

  @Test("Superseded started IO retires even while its replacement has no source data")
  func cancelledOwnerDoesNotWaitForIdleReplacement() async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let original = try #require(runtime.handle("A"))

    runtime.holdOperations["B"] = .commit
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("deferred-commit:B")
    let superseded = try #require(runtime.handle("B"))
    #expect(original.retired && superseded.ioRunning)

    runtime.holdArmed = ["C"]
    runtime.holdRetirement = ["B"]
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    try await runtime.wait("started:C")
    let replacement = try #require(runtime.handle("C"))
    try await runtime.wait("retire:B")
    #expect(superseded.cancelled && !superseded.ioRunning && !superseded.retired)
    #expect(superseded.retirementAttempts == 1)

    runtime.releaseOperation("B")
    try await runtime.wait("late-cancelled:B")
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

  @Test("Early retirement failure is joined, not retried when an idle replacement later arms")
  func earlyCancelledCleanupFailureDoesNotRetry() async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()

    runtime.holdOperations["B"] = .commit
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("deferred-commit:B")
    let superseded = try #require(runtime.handle("B"))

    let failure = AudioRouteFailure(stage: "retire", message: "Cancelled IO cleanup failed")
    runtime.holdArmed = ["C"]
    runtime.holdRetirement = ["B"]
    runtime.retirementCallbackFailure = failure
    runtime.retirementCallbackUsesCleanup = true
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    try await runtime.wait("started:C")
    runtime.releaseOperation("B")
    try await runtime.wait("late-cancelled:B")
    try await runtime.wait("retire:B")
    #expect(superseded.retirementAttempts == 1)

    runtime.holdRetirement = []
    runtime.retirementCallbackFailure = nil
    let replacement = try #require(runtime.handle("C"))
    replacement.arm()
    await controller.waitForCurrentWork()
    #expect(superseded.retirementAttempts == 1 && !superseded.retired)
    #expect(replacement.commits.isEmpty && controller.lastFailure == failure)

    superseded.finishRetirement(cleanupFailure: failure)
    await controller.shutdown()
    #expect(superseded.retirementAttempts == 1 && controller.lastFailure == failure)
  }

  @Test(
    "Explicit capture retry reattempts failed cleanup without hiding repeated errors",
    arguments: [false, true])
  func explicitRetryReattemptsFailedRetirement(recovers: Bool) async throws {
    let (controller, settings, runtime) = makeController()
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
    #expect(runtime.cleanupRetryRequests == 1)
    #expect(controller.unresolvedRetirementFailures[old.key] == cleanup)
    #expect(runtime.handle("B")?.commits.isEmpty == true)

    controller.observeOutputs([a, b], defaultUID: "A")
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 1)

    if recovers { old.retirementError = nil }
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(old.retirementAttempts == 2 && runtime.cleanupRetryRequests == 2)
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

  @Test("Explicit retry force-reprepares every app's route without switching devices")
  func explicitRetryForceRebuildsAllRoutes() async throws {
    let (controller, settings, runtime) = makeController()
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1,
      displayName: "Pinned", bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "B")
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application, pinned])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let following = try #require(runtime.handle("A"))
    let fixed = try #require(runtime.handle("B"))
    #expect(following.rendering && fixed.rendering)
    #expect(runtime.requests.count == 2)

    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()

    #expect(runtime.requests.count == 4)
    #expect(following.retired && !following.ioRunning)
    #expect(fixed.retired && !fixed.ioRunning)
    #expect(runtime.handle("A") !== following)
    #expect(runtime.handle("B") !== fixed)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["A"])
    #expect(controller.activeDeviceUIDs(for: pinned.identifier) == ["B"])
    #expect(controller.lastFailure == nil)
    await controller.shutdown()
  }

  @Test(
    "Repeated explicit retry joins PENDING cleanup and honors its current ACK",
    arguments: [false, true])
  func repeatedExplicitRetryJoinsPendingCleanup(ackFails: Bool) async throws {
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("retire:A:2")
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
    "A retry's early retired ACK cannot bypass its unsettled receipt",
    arguments: [false, true])
  func retryRetirementReceiptGatesNewPlan(receiptFails: Bool) async throws {
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("retirement-receipt:A")
    #expect(old.retired && controller.unresolvedRetirementFailures.isEmpty)

    let nextPrepare = runtime.requests.count + 1
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["A"]))
    try await runtime.wait("prepare:A:\(nextPrepare)")
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
    let (controller, settings, runtime) = makeController()
    runtime.holdPreparation = ["B"]
    controller.observeOutputs([a, b, c], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()

    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("prepare:B")
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["C"]))
    try await runtime.wait("commit:C")
    runtime.releasePreparation("B")
    await controller.waitForCurrentWork()
    try await runtime.wait("retired:B")

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
    "A binding failure remains diagnostic history, not a failure of successful old-route retirement",
    arguments: [false, true], [false, true])
  func bindingChangeRecoversAfterOldRouteRetires(pending: Bool, switchOutput: Bool) async throws {
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("retire:A")
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
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))
    old.finishRetirement()
    await controller.waitForCurrentWork()
    #expect(candidate.commits.isEmpty && !candidate.rendering)
    #expect(controller.lastFailure == cleanup)
    await controller.shutdown()
  }

  @Test("Stop shares pending retirement and shutdown collects both owners exactly once")
  func stopDuringPendingRetirementSharesOwner() async throws {
    let (controller, settings, runtime) = makeController()
    runtime.holdRetirement = ["A"]
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))

    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))
    controller.perform(.stopCapture)
    old.finishRetirement()
    await controller.shutdown()

    #expect(old.retirementAttempts == 1)
    #expect(candidate.retirementAttempts == 1)
    #expect(old.retired && candidate.retired && !old.rendering && !candidate.rendering)
    #expect(candidate.commits.isEmpty && controller.captureIntent == .none)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test(
    "A failed same target retries through route/start or an explicit Retry",
    arguments: [DeviceSelectionMode.single, .multi], [false, true])
  func failedSameTargetCanRetry(mode: DeviceSelectionMode, retryStart: Bool) async throws {
    let (controller, settings, runtime) = makeController()
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
    if retryStart {
      // Retry rebuilds every route, including a still-healthy output in a multi route.
      #expect(runtime.requests.count == (mode == .multi ? 4 : 3))
      #expect(original.retirementAttempts == 1)
    } else {
      #expect(runtime.requests.count == 3)
      #expect(original.retirementAttempts == (mode == .single ? 1 : 0))
    }
    #expect(settings.getSelectedDeviceUIDs(for: application.identifier) == desired)
    await controller.shutdown()
  }

  @Test(
    "Retirement errors survive callback/receipt ordering and successful quiescence acknowledgements",
    arguments: [false, true], ControlRetirementFailureOrder.allCases)
  func errorBeforePendingRetirementRejectsCommit(
    cleanupChannel: Bool, order: ControlRetirementFailureOrder
  ) async throws {
    let (controller, _, runtime) = makeController()
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
    try await runtime.wait("retire:A")
    let candidate = try #require(runtime.handle("B"))

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
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a, b], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let old = try #require(runtime.handle("A"))

    let failure = AudioRouteFailure(
      stage: "start-cleanup", message: "Callback start cleanup failure")
    if afterReceipt { runtime.holdArmed = ["B"] } else { runtime.startCleanupFailure = failure }
    controller.perform(.setRoute(identifier: application.identifier, mode: .single, uids: ["B"]))
    try await runtime.wait("started:B")
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

  @Test(
    "Stopping capture retains unresolved retirement debt until retired ACK arrives",
    arguments: [false, true])
  func stopCaptureRetainsUnresolvedRetirementDebt(cleanupChannel: Bool) async throws {
    let (controller, _, runtime) = makeController()
    controller.observeOutputs([a], defaultUID: "A")
    controller.observeApplications([application])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))

    let cleanup = AudioRouteFailure(stage: "stop", code: 560_227_702, message: "Cleanup is blocked")
    runtime.holdRetirement = ["A"]
    runtime.retirementCallbackFailure = cleanup
    runtime.retirementCallbackUsesCleanup = cleanupChannel
    controller.perform(.stopCapture)
    await controller.shutdown()

    #expect(!route.retired && controller.unresolvedRetirementFailures[route.key] == cleanup)
    route.finishRetirement(
      failure: cleanupChannel ? nil : cleanup, cleanupFailure: cleanupChannel ? cleanup : nil)
    #expect(controller.unresolvedRetirementFailures[route.key] == nil)
    let history = try #require(controller.routeObservations[route.key])
    #expect((cleanupChannel ? history.cleanupFailure : history.failure) == cleanup)
  }
}
