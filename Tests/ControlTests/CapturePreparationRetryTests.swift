import FineTuneControl
import FineTuneDomain
import Testing

@Suite("Capture preparation retry admission", .timeLimit(.minutes(1)))
@MainActor
struct CapturePreparationRetryTests {
  @Test(
    "A failed capture attempt is not reopened by passive observations",
    arguments: [false, true])
  func failedPreparationDoesNotRetryFromPassiveObservations(readTapFailure: Bool) async {
    let failure = AudioRouteFailure(
      kind: readTapFailure ? .unsupported : .nativeFailure,
      stage: readTapFailure ? "inspectTap" : "createTap", code: -7201,
      message: "The actual preparation failed without an authorization result.")
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(failure: failure)
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(controller.routeFailure == failure)

    for _ in 0..<3 {
      controller.observeOutputs([output()], defaultUID: "A")
      controller.observeApplications([application()])
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
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(failure: failure, holdFirst: true)
    defer { runtime.releaseFirst() }
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    try await self.waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)
    #expect(runtime.requests.count == 1)

    // Passive observations reconcile synchronously and may only replace the pending plan.
    for revision in UInt64(2)...4 {
      controller.observeApplications([application(revision: revision)])
      controller.observeOutputs([output(revision: revision)], defaultUID: "A")
    }
    #expect(runtime.requests.count == 1)
    #expect(runtime.maximumOutstandingPreparations == 1)

    runtime.releaseFirst()
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(runtime.cleanupRetryRequests == 0)
    #expect(controller.routeFailure == failure)
    #expect(!runtime.cancelledFirstResult)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)

    // The retained preparation failure survives later passive binding churn as well.
    for revision in UInt64(5)...6 {
      controller.observeApplications([application(revision: revision)])
      controller.observeOutputs([output(revision: revision)], defaultUID: "A")
      // Any work these passive observations attempted must settle before the no-retry check.
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
    let failure = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7211,
      message: "The held native preparation returned E1.")
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(failure: failure, holdFirst: true)
    defer { runtime.releaseFirst() }
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    try await self.waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)
    if retryStart {
      controller.perform(.requestCaptureStart)
    } else {
      controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["A"]))
    }
    // The gate proves the explicit retry acquires while the old preparation is still unresolved.
    try await self.waitForPreparationStarted(count: 2, runtime: runtime, controller: controller)
    #expect(runtime.requests.count == 2)
    // The second attempt's failure is authoritative even while the superseded first attempt waits.
    let retriedFailure = controller.captureRetryFailure
    #expect(retriedFailure?.kind == .nativeFailure)
    #expect(retriedFailure?.stage == "createTap")
    #expect(retriedFailure?.code == -7212)
    #expect(controller.routeFailure == retriedFailure)

    runtime.releaseFirst()
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(controller.captureRetryFailure == retriedFailure)
    #expect(controller.routeFailure == retriedFailure)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(controller.captureRetryFailure == retriedFailure)
    #expect(!controller.knownPermissionDenied)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test("A successful pending attempt retires its stale owner and uses only the latest binding")
  func successfulPendingReplacementUsesLatestBinding() async throws {
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(
      failure: AudioRouteFailure(stage: "unit", message: "Unused successful fixture failure"),
      holdFirst: true, returnsOwners: true)
    defer { runtime.releaseFirst() }
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    try await self.waitForPreparationStarted(count: 1, runtime: runtime, controller: controller)
    for revision in UInt64(2)...3 {
      controller.observeApplications([application(revision: revision)])
      controller.observeOutputs([output(revision: revision)], defaultUID: "A")
    }
    #expect(runtime.requests.count == 1)
    runtime.releaseFirst()
    try await self.waitForPreparationStarted(count: 2, runtime: runtime, controller: controller)
    await controller.waitForCurrentWork()

    #expect(runtime.requests.count == 2)
    #expect(runtime.maximumOutstandingPreparations == 1)
    #expect(runtime.requests.last?.processRevision == 3)
    let stale = try #require(runtime.owners.first)
    let current = try #require(runtime.owners.last)
    #expect(stale.key != current.key)
    #expect(stale.retired && stale.commits.isEmpty)
    #expect(current.commits.count == 1)
    #expect(controller.activeDeviceUIDs(for: "unit.player") == ["A"])
    #expect(controller.captureRetryFailure == nil)
    #expect(!controller.knownPermissionDenied)
    await controller.shutdown()
    #expect(current.retired)
  }

  /// A bounded wait failure releases the held preparation and settles the controller before the
  /// original timeout or cancellation reaches the test.
  private func waitForPreparationStarted(
    count: Int, runtime: CaptureRetryRuntime, controller: AudioController
  ) async throws {
    do {
      try await runtime.waitForPreparationStarted(count: count)
    } catch {
      runtime.releaseFirst()
      await controller.shutdown()
      throw error
    }
  }

  private func controller(
    settings: CaptureRetryMemorySettings, runtime: CaptureRetryRuntime
  ) -> AudioController {
    AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
  }

  private func application(revision: UInt64 = 1) -> AudioApplicationDescriptor {
    AudioApplicationDescriptor(
      identifier: "unit.player", processID: 101, processRevision: revision,
      displayName: "Player", bundleID: "unit.player")
  }

  private func output(revision: UInt64 = 1) -> AudioOutputDescriptor {
    AudioOutputDescriptor(
      uid: "A", bindingRevision: revision, supportsAutoEQ: false,
      processingGain: 1, volume: 0.5, isMuted: false)
  }
}

/// Models only the public runtime outcome, including the production factory's cancellation
/// precedence. It never imports Platform, calls native code, or asserts that permission exists.
@MainActor
private final class CaptureRetryRuntime: AudioRoutingRuntime {
  private(set) var cleanupRetryRequests = 0
  private(set) var requests: [AudioRouteRequest] = []
  private(set) var maximumOutstandingPreparations = 0
  private(set) var cancelledFirstResult = false
  private(set) var owners: [CaptureRetryRoute] = []
  private let failure: AudioRouteFailure
  private let holdFirst: Bool
  private let returnsOwners: Bool
  private var outstandingPreparations = 0
  private var firstGate: CheckedContinuation<Void, Never>?
  private var firstReleased = false
  private var startWaiters: [Int: CapturePreparationGateWaiter] = [:]
  private var nextStartWaiterID = 0

  /// One explicit deadline bounds every wait; the gate neither polls nor retries.
  private static let preparationStartFailureDeadline: Duration = .seconds(5)

  init(failure: AudioRouteFailure, holdFirst: Bool = false, returnsOwners: Bool = false) {
    self.failure = failure
    self.holdFirst = holdFirst
    self.returnsOwners = returnsOwners
  }

  func requestCleanupRetry() { cleanupRetryRequests += 1 }

  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    let isFirst = requests.isEmpty
    requests.append(request)
    outstandingPreparations += 1
    maximumOutstandingPreparations = max(
      maximumOutstandingPreparations, outstandingPreparations)
    resumeStartWaiters()
    defer { outstandingPreparations -= 1 }
    if isFirst && holdFirst {
      if !firstReleased {
        await withCheckedContinuation { continuation in
          firstGate = continuation
        }
      }
      // NativeAudioRoutingRuntime gives cancellation precedence over packet.failure.
      if Task.isCancelled {
        cancelledFirstResult = true
        throw AudioRouteFailure(kind: .cancelled, stage: "prepare", message: "Cancelled E1")
      }
    } else if holdFirst && !returnsOwners {
      throw AudioRouteFailure(
        kind: .nativeFailure, stage: "createTap", code: -7212,
        message: "An incorrectly submitted second acquisition returned E2.")
    }
    if returnsOwners {
      let owner = CaptureRetryRoute(key: request.key)
      owners.append(owner)
      return owner
    }
    throw failure
  }

  /// Cumulative event gate: waits until `count` preparations have started in total.
  ///
  /// A canceled wait resumes with `CancellationError`; a wait that reaches its one 5-second
  /// deadline throws `CapturePreparationGateTimeout`, so a missing start fails the test instead
  /// of leaving its continuation suspended forever.
  func waitForPreparationStarted(count: Int) async throws {
    guard requests.count < count else { return }
    let waiterID = nextStartWaiterID
    nextStartWaiterID += 1
    let failureDeadline = Self.preparationStartFailureDeadline
    // Pin the continuation's result type and keep it out of the operation's return position:
    // Swift 6.4.2 otherwise fails to type-check this cancellation-handler call and reports only
    // "failed to produce diagnostic for expression". The gate itself is unchanged.
    try await withTaskCancellationHandler {
      _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        // One explicit deadline per wait keeps the cumulative gate bounded without polling.
        let timeout = Task { @MainActor [weak self] in
          try? await Task.sleep(for: failureDeadline)
          guard !Task.isCancelled else { return }
          self?.expireStartWaiter(waiterID, failureDeadline: failureDeadline)
        }
        startWaiters[waiterID] = CapturePreparationGateWaiter(
          expectedCount: count, continuation: continuation, timeout: timeout)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelStartWaiter(waiterID)
      }
    }
  }

  private func resumeStartWaiters() {
    for waiterID in startWaiters.filter({ requests.count >= $0.value.expectedCount }).keys {
      guard let waiter = startWaiters.removeValue(forKey: waiterID) else { continue }
      waiter.timeout.cancel()
      waiter.continuation.resume()
    }
  }

  /// Fails the one gate wait whose target start count was never reached within the deadline.
  private func expireStartWaiter(_ waiterID: Int, failureDeadline: Duration) {
    guard let waiter = startWaiters.removeValue(forKey: waiterID) else { return }
    waiter.continuation.resume(
      throwing: CapturePreparationGateTimeout(
        failureDeadline: failureDeadline, expectedCount: waiter.expectedCount,
        observedCount: requests.count))
  }

  private func cancelStartWaiter(_ waiterID: Int) {
    guard let waiter = startWaiters.removeValue(forKey: waiterID) else { return }
    waiter.timeout.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }

  /// Sticky release: cleanup may run before the delayed first preparation installs its gate.
  func releaseFirst() {
    firstReleased = true
    firstGate?.resume()
    firstGate = nil
  }
}

/// One pending cumulative start wait and its single bounded failure task.
private struct CapturePreparationGateWaiter {
  let expectedCount: Int
  let continuation: CheckedContinuation<Void, any Error>
  let timeout: Task<Void, Never>
}

/// The preparation-start gate missed its single failure deadline.
private struct CapturePreparationGateTimeout: Error, CustomStringConvertible, Sendable {
  let failureDeadline: Duration
  let expectedCount: Int
  let observedCount: Int

  var description: String {
    "Timed out after \(failureDeadline.components.seconds) seconds waiting for preparation "
      + "attempt \(expectedCount) to start; observed \(observedCount) request(s)."
  }
}

@MainActor
private final class CaptureRetryRoute: PreparedAudioRoute {
  let key: AudioRouteKey
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  private(set) var commits: [AudioOutputState] = []
  private(set) var retired = false
  private(set) var cancelled = false
  private(set) var levels: AudioOutputLevels?

  init(key: AudioRouteKey) { self.key = key }
  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    AudioRouteObservation(key: key, phase: .armed, acceptedRevision: state.revision)
  }
  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    commits.append(state)
    return AudioRouteObservation(
      key: key, phase: .committed, acceptedRevision: state.revision,
      appliedRevision: state.revision)
  }
  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    AudioRouteObservation(key: key, phase: .committed, acceptedRevision: state.revision)
  }
  func requestLevels(_ levels: AudioOutputLevels) { self.levels = levels }
  func cancel() { cancelled = true }
  func retire() async -> AudioRetirementResult {
    retired = true
    return .retired
  }
}

/// Real in-memory preference values for the public Control port; no files or OS services.
@MainActor
private final class CaptureRetryMemorySettings: AudioControlSettingsStore {
  var appSettings: AppSettings
  var autoEQPreampEnabled = true
  var favoriteAutoEQProfileIDs: Set<String> = []
  let devicePriorityOrder: [String] = []
  private var volumes: [String: Float] = [:]
  private var mutes: [String: Bool] = [:]
  private var boosts: [String: BoostLevel] = [:]
  private var modes: [String: DeviceSelectionMode] = [:]
  private var selections: [String: Set<String>] = [:]
  private var routes: [String: String] = [:]
  private var equalizers: [String: EQSettings] = [:]
  private var pinned: Set<String> = []
  private var ignored: Set<String> = []
  private var profiles: [String: AutoEQSelection] = [:]

  init() {
    var settings = AppSettings()
    settings.explicitUserCaptureEnabled = true
    appSettings = settings
  }

  func updateAppSettings(_ settings: AppSettings) { appSettings = settings }
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
  func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? { selections[identifier] }
  func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
    selections[identifier] = uids
  }
  func getDeviceRouting(for identifier: String) -> String? { routes[identifier] }
  func setDeviceRouting(for identifier: String, deviceUID: String) {
    routes[identifier] = deviceUID
  }
  func isFollowingDefault(for identifier: String) -> Bool {
    routes[identifier] == nil && selections[identifier] == nil
  }
  func setFollowDefault(for identifier: String) {
    routes[identifier] = nil
    selections[identifier] = nil
  }
  func getEQSettings(for identifier: String) -> EQSettings { equalizers[identifier] ?? .flat }
  func setEQSettings(_ settings: EQSettings, for identifier: String) {
    equalizers[identifier] = settings
  }
  func isPinned(_ identifier: String) -> Bool { pinned.contains(identifier) }
  func isIgnored(_ identifier: String) -> Bool { ignored.contains(identifier) }
  func setAppPinned(_ identifier: String, pinned: Bool, displayName: String?, bundleID: String?) {
    if pinned { self.pinned.insert(identifier) } else { self.pinned.remove(identifier) }
  }
  func setAppIgnored(_ identifier: String, ignored: Bool, displayName: String?, bundleID: String?) {
    if ignored { self.ignored.insert(identifier) } else { self.ignored.remove(identifier) }
  }
  func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? { profiles[deviceUID] }
  func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
    profiles[deviceUID] = selection
  }
  func setAutoEQFavorite(profileID: String, favorite: Bool) {
    if favorite {
      favoriteAutoEQProfileIDs.insert(profileID)
    } else {
      favoriteAutoEQProfileIDs.remove(profileID)
    }
  }
  func resetAllSettings() {
    appSettings = AppSettings()
    volumes.removeAll()
    mutes.removeAll()
    boosts.removeAll()
    modes.removeAll()
    selections.removeAll()
    routes.removeAll()
    equalizers.removeAll()
    pinned.removeAll()
    ignored.removeAll()
    profiles.removeAll()
    favoriteAutoEQProfileIDs.removeAll()
    autoEQPreampEnabled = true
  }
}
