import FineTuneControl
import FineTuneDomain
import Testing

@Suite("Control: Default output routing policy coordination", .timeLimit(.minutes(1)))
@MainActor
struct AudioControllerDefaultRoutingTests {
  private let application = AudioApplicationDescriptor(
    identifier: "unit.player", processID: 101, processRevision: 1,
    displayName: "Player", bundleID: "unit.player")
  private let a = AudioOutputDescriptor(
    uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 0.25, volume: 0.6,
    isMuted: false)
  private let b = AudioOutputDescriptor(
    uid: "B", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 0.8,
    isMuted: false)

  @Test(
    "Selecting an output retries failed following routes, not pinned routes or input selections")
  func defaultOutputSelectionRetriesFailedFollowingRoutes() async throws {
    let settings = InMemoryControlSettingsStore()
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1,
      displayName: "Pinned", bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "A")
    let runtime = ControlledRoutingRuntime()
    let failure = AudioRouteFailure(
      kind: .unsupported, stage: "certifyFormat", code: -5101, message: "Initial format rejected")
    runtime.prepareFailure = failure
    let writerFailure = MutableBox<AudioRouteFailure?>(
      AudioRouteFailure(stage: "output-write", message: "Write rejected"))
    let policy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { _ in
        if let failure = writerFailure.value { throw failure }
      })
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

    writerFailure.value = nil
    controller.perform(.setDefaultDevice(scope: .output, uid: "B"))
    await controller.waitForCurrentWork()
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

  @Test(
    "A late default candidate cannot commit after an approved routing target changes",
    arguments: [false, true])
  func pendingDefaultCandidateRechecksApprovedTarget(notifySnapshot: Bool) async throws {
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let decision = MutableBox<ControlDefaultOutputRoutingDecision>(.followObserved)
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
    try await runtime.wait("prepare:B")
    decision.value = .routeToApprovedUID("A")
    if notifySnapshot { controller.observeOutputs([a, b], defaultUID: "B") }
    runtime.releasePreparation("B")
    await controller.waitForCurrentWork()

    let candidate = try #require(runtime.handle("B"))
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
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let clock = ControlManualTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) })
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
    try await runtime.wait("prepare:A")

    try policy.selectDefaultOutput(uid: "B")
    #expect(writes == ["B"] && policy.intendedDefaultUID == "B")
    #expect(controller.defaultOutputUID == "A")
    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()

    let pending = try #require(runtime.handle("A"))
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
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
    let high = AudioOutputDescriptor(
      uid: "High", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 1,
      isMuted: false)
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1,
      displayName: "Pinned", bundleID: "unit.pinned")
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
      readDefaultRoutingDecision: { policy.routingDecision() })
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
    let settings = InMemoryControlSettingsStore()
    let runtime = ControlledRoutingRuntime()
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

  @Test("Rejected lower Bluetooth auto-switch keeps following apps on approved mid UID")
  func failedRestoreDoesNotRetargetFollowingApp() async throws {
    let settings = InMemoryControlSettingsStore()
    settings.setDevicePriorityOrder(["high", "mid", "low"])
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1,
      displayName: "Pinned", bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "high")

    var restores: [String] = []
    let policy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { uid in
        restores.append(uid)
        throw AudioRouteFailure(stage: "output-write", message: "Restore Mid failed")
      })
    defer { policy.suspend() }

    let runtime = ControlledRoutingRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { policy.routingDecision() })
    let high = AudioOutputDescriptor(
      uid: "high", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)
    let mid = AudioOutputDescriptor(
      uid: "mid", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)
    let low = AudioOutputDescriptor(
      uid: "low", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)

    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "mid", bluetoothUIDs: [])
    controller.observeOutputs([high, mid], defaultUID: "mid")
    controller.observeApplications([application, pinned])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let midRoute = try #require(runtime.handle("mid"))
    let highRoute = try #require(runtime.handle("high"))
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["mid"])
    #expect(controller.activeDeviceUIDs(for: pinned.identifier) == ["high"])

    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "mid", bluetoothUIDs: ["low"])
    controller.observeOutputs([high, mid, low], defaultUID: "mid")
    await controller.waitForCurrentWork()
    #expect(policy.graceConnectionUID == "low" && policy.graceDuration == .seconds(5))

    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
    controller.observeOutputs([high, mid, low], defaultUID: "low")
    await controller.waitForCurrentWork()

    #expect(restores == ["mid"])
    #expect(policy.intendedDefaultUID == "mid" && policy.observedDefaultUID == "low")
    #expect(runtime.requests.filter { $0.key.deviceUID == "low" }.isEmpty)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["mid"])
    #expect(midRoute.rendering && !midRoute.retired)
    #expect(controller.activeDeviceUIDs(for: pinned.identifier) == ["high"])
    #expect(highRoute.rendering && !highRoute.retired)
    await controller.shutdown()
  }

  @Test(
    "Explicit output settling repairs Bluetooth rebound while preserving following and pinned owners"
  )
  func manualBluetoothReboundKeepsApprovedFollowingOwner() async throws {
    let settings = InMemoryControlSettingsStore()
    settings.setDevicePriorityOrder(["high", "mid", "low"])
    let pinned = AudioApplicationDescriptor(
      identifier: "unit.pinned", processID: 102, processRevision: 1,
      displayName: "Pinned", bundleID: "unit.pinned")
    settings.setDeviceRouting(for: pinned.identifier, deviceUID: "high")

    var restores: [String] = []
    let clock = ControlManualTestClock()
    let policy = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { restores.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }

    let runtime = ControlledRoutingRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { policy.routingDecision() },
      deviceCommand: { command in
        if case .setDefaultDevice(.output, let uid) = command {
          try policy.selectDefaultOutput(uid: uid)
        }
      })
    let high = AudioOutputDescriptor(
      uid: "high", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)
    let mid = AudioOutputDescriptor(
      uid: "mid", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)
    let low = AudioOutputDescriptor(
      uid: "low", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
      isMuted: false)

    func observeDefault(_ uid: String, at instant: Double) {
      clock.now = instant
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: uid, bluetoothUIDs: ["low"])
      controller.observeOutputs([high, mid, low], defaultUID: uid)
    }

    observeDefault("low", at: 0)
    controller.observeApplications([application, pinned])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let pinnedRoute = try #require(runtime.handle("high"))
    #expect(runtime.requests.count == 2 && policy.graceConnectionUID == nil)

    controller.perform(.setDefaultDevice(scope: .output, uid: "mid"))
    await controller.waitForCurrentWork()
    let following = try #require(runtime.handle("mid"))
    #expect(restores == ["mid"] && runtime.requests.count == 3)

    observeDefault("mid", at: 0.05)
    await controller.waitForCurrentWork()
    observeDefault("low", at: 0.3)
    await controller.waitForCurrentWork()
    #expect(restores == ["mid", "mid"])
    #expect(policy.intendedDefaultUID == "mid" && policy.lastFailure == nil)
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["mid"])
    #expect(following.rendering && !following.retired)
    #expect(pinnedRoute.rendering && pinnedRoute.retirementAttempts == 0)

    observeDefault("mid", at: 0.35)
    await controller.waitForCurrentWork()
    #expect(policy.intendedDefaultUID == "mid" && policy.pendingDefaultUID == nil)

    observeDefault("low", at: 2.001)
    await controller.waitForCurrentWork()
    #expect(policy.intendedDefaultUID == "low" && policy.observedDefaultUID == "low")
    #expect(controller.activeDeviceUIDs(for: application.identifier) == ["low"])
    #expect(runtime.requests.count == 4)
    #expect(pinnedRoute.rendering && pinnedRoute.retirementAttempts == 0)
    await controller.shutdown()
  }
}
