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
    #expect(controller.routeFailure == failure)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test("Passive binding churn cannot stack acquisitions or erase the pending native failure")
  func pendingPassiveChurnDoesNotAccumulateAcquisitions() async {
    let failure = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7211,
      message: "The held native preparation returned E1.")
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(failure: failure, holdFirst: true)
    defer { runtime.releaseFirst() }
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    await runtime.waitForFirstPreparation()
    #expect(runtime.requests.count == 1)

    for revision in UInt64(2)...4 {
      controller.observeApplications([application(revision: revision)])
      controller.observeOutputs([output(revision: revision)], defaultUID: "A")
      // Let scheduled MainActor routing work run without a real clock or OS operation.
      await Task.yield()
    }
    #expect(runtime.requests.count == 1)
    #expect(runtime.maximumOutstandingPreparations == 1)

    runtime.releaseFirst()
    await controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(controller.routeFailure == failure)
    #expect(!runtime.cancelledFirstResult)
    #expect(!controller.knownPermissionDenied)
    #expect(controller.captureIntent != .none)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test(
    "An explicit same-target retry starts a fresh attempt before the old one settles",
    arguments: [false, true])
  func explicitSameTargetRetrySupersedesPendingAttempt(retryStart: Bool) async {
    let failure = AudioRouteFailure(
      kind: .nativeFailure, stage: "createTap", code: -7211,
      message: "The held native preparation returned E1.")
    let settings = CaptureRetryMemorySettings()
    let runtime = CaptureRetryRuntime(failure: failure, holdFirst: true)
    defer { runtime.releaseFirst() }
    let controller = self.controller(settings: settings, runtime: runtime)
    controller.observeOutputs([output()], defaultUID: "A")
    controller.observeApplications([application()])
    await runtime.waitForFirstPreparation()
    if retryStart {
      controller.perform(.requestCaptureStart)
    } else {
      controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["A"]))
    }
    // Give the newly scheduled explicit work actor turns while P1 remains unresolved.
    for _ in 0..<3 { await Task.yield() }
    #expect(runtime.requests.count == 2)
    let retriedFailure = controller.captureRetryFailure
    #expect(retriedFailure?.kind == .nativeFailure)
    #expect(retriedFailure?.stage == "createTap")
    #expect(retriedFailure?.code == -7212)

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
    await runtime.waitForFirstPreparation()
    for revision in UInt64(2)...3 {
      controller.observeApplications([application(revision: revision)])
      controller.observeOutputs([output(revision: revision)], defaultUID: "A")
      await Task.yield()
    }
    #expect(runtime.requests.count == 1)
    runtime.releaseFirst()
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
  func requestCleanupRetry() { cleanupRetryRequests += 1 }
  private(set) var requests: [AudioRouteRequest] = []
  private(set) var maximumOutstandingPreparations = 0
  private(set) var cancelledFirstResult = false
  private(set) var owners: [CaptureRetryRoute] = []
  private let failure: AudioRouteFailure
  private let holdFirst: Bool
  private let returnsOwners: Bool
  private var outstandingPreparations = 0
  private var firstGate: CheckedContinuation<Void, Never>?
  private var firstEntered: CheckedContinuation<Void, Never>?

  init(failure: AudioRouteFailure, holdFirst: Bool = false, returnsOwners: Bool = false) {
    self.failure = failure
    self.holdFirst = holdFirst
    self.returnsOwners = returnsOwners
  }

  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    let isFirst = requests.isEmpty
    requests.append(request)
    outstandingPreparations += 1
    maximumOutstandingPreparations = max(
      maximumOutstandingPreparations, outstandingPreparations)
    defer { outstandingPreparations -= 1 }
    if isFirst && holdFirst {
      await withCheckedContinuation { continuation in
        firstGate = continuation
        firstEntered?.resume()
        firstEntered = nil
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

  func waitForFirstPreparation() async {
    if !requests.isEmpty { return }
    await withCheckedContinuation { firstEntered = $0 }
  }

  func releaseFirst() {
    firstGate?.resume()
    firstGate = nil
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
