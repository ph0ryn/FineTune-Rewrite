import FineTuneDomain
import Foundation
import Observation

/// Physical default-output policy. App route wishes remain in AudioController/the same saved store.
/// A successful writer records requested intent, never a fabricated observed default UID.
@Observable @MainActor
public final class OutputDevicePolicyController {
  private let settings: any OutputDevicePolicySettingsStore
  private let setDefaultOutput: @MainActor (String) throws -> Void
  private let now: @MainActor () -> Double
  private let grace: DeviceAutoSwitchGrace
  private let echoes: DeviceDefaultEchoes
  public private(set) var availableUIDs: [String] = []
  public private(set) var observedDefaultUID: String?
  public private(set) var intendedDefaultUID: String?
  public var pendingDefaultUID: String? { pendingRequest?.uid }
  private struct PendingRequest: Equatable {
    let uid: String
    let token: UInt64
  }
  private struct ExplicitSelection: Equatable {
    let uid: String
    let deadline: Double
    var canCorrect = true
    var didCorrect = false
  }
  private var pendingRequest: PendingRequest?
  private var explicitSelection: ExplicitSelection?
  private var requestRevision: UInt64 = 0
  private var acceptedRequestRevision: UInt64 = 0
  private var failureRevision: UInt64 = 0
  private static let selectionNotRetained = AudioRouteFailure(
    kind: .bindingChanged, stage: "output-selection",
    message: "Unable to keep the selected output. Select it again to retry.")
  public private(set) var observationFailure: AudioRouteFailure?
  public private(set) var operationFailure: AudioRouteFailure?
  public var graceConnectionUID: String? { grace.uid }
  public var graceDuration: Duration? { grace.duration }
  public var lastFailure: AudioRouteFailure? { observationFailure ?? operationFailure }
  private var bluetoothUIDs: Set<String> = []
  private var hasObservation = false
  private var suspended = false
  private var previousPriority: [String]
  private var lastOverrideTime: Double?

  public init(
    settings: any OutputDevicePolicySettingsStore,
    setDefaultOutput: @escaping @MainActor (String) throws -> Void,
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.settings = settings
    self.setDefaultOutput = setDefaultOutput
    self.now = now
    grace = DeviceAutoSwitchGrace(sleep: sleep)
    echoes = DeviceDefaultEchoes(sleep: sleep)
    previousPriority = settings.devicePriorityOrder
    grace.onFailure = { [weak self] error in self?.recordFailure(error) }
    echoes.onFailure = { [weak self] error in self?.recordFailure(error) }
    echoes.onTimeout = { [weak self] token, _ in
      guard let self, !self.suspended, self.pendingRequest?.token == token else { return }
      self.pendingRequest = nil
      guard self.observationFailure == nil else { return }
      if let selection = self.explicitSelection, self.intendedDefaultUID == selection.uid {
        guard self.observedDefaultUID != selection.uid else { return }
        // A corrective lease can outlive the fixed window; it must never restart a write loop.
        self.failExplicitSelection()
        return
      }
      do { try self.restoreIntendedDefault() } catch { self.recordFailure(error) }
    }
  }

  isolated deinit {
    grace.cancel()
    echoes.cancelAll()
  }

  /// Keep the approved app-routing target separate from a failed physical-default restoration.
  public func routingDecision() -> ControlDefaultOutputRoutingDecision {
    guard let intendedDefaultUID else {
      return .followObserved
    }
    return .routeToApprovedUID(intendedDefaultUID)
  }

  public func observe(
    availableUIDs: [String], defaultUID: String?, bluetoothUIDs: Set<String>, failure: String? = nil
  ) {
    if let failure {
      explicitSelection?.canCorrect = false
      observationFailure = AudioRouteFailure(stage: "output-observation", message: failure)
      return
    }
    let current = Set(availableUIDs)
    guard current.count == availableUIDs.count, !current.contains(""),
      bluetoothUIDs.isSubset(of: current)
    else {
      explicitSelection?.canCorrect = false
      observationFailure = AudioRouteFailure(
        kind: .bindingChanged, stage: "output-observation",
        message: "Output observation contains invalid or inconsistent UID bindings.")
      return
    }
    let initialized = hasObservation
    let oldDefault = observedDefaultUID
    let removed = Set(self.availableUIDs).subtracting(current)
    let connected = current.subtracting(self.availableUIDs)
    if !connected.isEmpty || !removed.isEmpty || self.bluetoothUIDs != bluetoothUIDs {
      explicitSelection?.canCorrect = false
    }
    self.availableUIDs = availableUIDs
    self.bluetoothUIDs = bluetoothUIDs
    observedDefaultUID = defaultUID
    observationFailure = nil
    hasObservation = true
    guard !suspended else { return }
    // Compute callback ordering before registration changes the saved priority list.
    let connectedOrder =
      settings.devicePriorityOrder.filter(connected.contains)
      + connected.subtracting(settings.devicePriorityOrder).sorted()
    for uid in initialized ? connectedOrder : availableUIDs { settings.ensureDeviceInPriority(uid) }
    previousPriority = settings.devicePriorityOrder
    if !initialized {
      intendedDefaultUID = defaultUID.flatMap { current.contains($0) ? $0 : nil }
      return
    }
    if let uid = grace.uid, removed.contains(uid) {
      grace.cancel()
      lastOverrideTime = nil
    }
    let defaultChanged = oldDefault != defaultUID
    let ownEcho = defaultChanged && defaultUID.map(echoes.consume) == true
    if ownEcho, pendingDefaultUID == defaultUID { pendingRequest = nil }
    if let selection = explicitSelection, current.contains(selection.uid),
      defaultUID == selection.uid,
      operationFailure == Self.selectionNotRetained
    {
      operationFailure = nil
    }
    do {
      if let selection = explicitSelection, selection.canCorrect,
        intendedDefaultUID == selection.uid, current.contains(selection.uid),
        let defaultUID, defaultUID != selection.uid, bluetoothUIDs.contains(defaultUID),
        now() < selection.deadline
      {
        if selection.didCorrect {
          failExplicitSelection()
        } else {
          // Reserve the sole correction before the writer, which may acknowledge reentrantly.
          explicitSelection?.didCorrect = true
          try request(selection.uid, force: true)
        }
        return
      }
      if let selection = explicitSelection, now() >= selection.deadline,
        defaultChanged, !ownEcho, let defaultUID, current.contains(defaultUID)
      {
        // A fresh external choice ends correction authority, including its outstanding timeout.
        if pendingDefaultUID == selection.uid { pendingRequest = nil }
        explicitSelection = nil
        if operationFailure == Self.selectionNotRetained { operationFailure = nil }
      }
      if oldDefault.map(removed.contains) == true
        || intendedDefaultUID.map(removed.contains) == true
      {
        if let target = highestPriority() { try request(target) }
      }
      // Same ordering as the upstream producer: listed priority first, then deterministic unknowns.
      for uid in connectedOrder {
        if uid == highestPriority() {
          try request(uid)
        } else if defaultUID == uid, !ownEcho {
          try restoreIntendedDefault()
        }
        grace.start(uid: uid, bluetooth: bluetoothUIDs.contains(uid))
        lastOverrideTime = nil
      }
      guard defaultChanged, !ownEcho, let defaultUID else { return }
      if let pending = grace.uid, defaultUID == pending {
        if let lastOverrideTime, now() - lastOverrideTime > 1 {
          grace.cancel()
          self.lastOverrideTime = nil
          intendedDefaultUID = defaultUID
          return
        }
        try restoreIntendedDefault()
        lastOverrideTime = now()
        grace.start(uid: pending, bluetooth: bluetoothUIDs.contains(pending))
        return
      }
      // Unknown-before-device-list is not an observed eligible default; wait for healthy topology.
      guard current.contains(defaultUID), pendingRequest == nil else { return }
      grace.cancel()
      lastOverrideTime = nil
      intendedDefaultUID = defaultUID
    } catch { recordFailure(error) }
  }

  /// UI selection must enter here, so its acknowledgement is consumed before the auto-switch branch.
  public func selectDefaultOutput(uid: String) throws {
    // A new explicit attempt supersedes old hotplug and correction authority.
    grace.cancel()
    lastOverrideTime = nil
    // Retain older echo tokens as provenance, but revoke their timeout/write authority.
    pendingRequest = nil
    explicitSelection = nil
    do {
      let revision = try request(uid, force: true)
      if acceptedRequestRevision == revision {
        explicitSelection = ExplicitSelection(uid: uid, deadline: now() + 2)
      }
    } catch {
      recordFailure(error)
      throw error
    }
  }

  public func settingsDidChange() {
    let changed = previousPriority != settings.devicePriorityOrder
    previousPriority = settings.devicePriorityOrder
    guard changed, !suspended, hasObservation, observationFailure == nil,
      let target = highestPriority()
    else { return }
    explicitSelection?.canCorrect = false
    do { try request(target) } catch { recordFailure(error) }
  }

  public func suspend() {
    suspended = true
    explicitSelection = nil
    pendingRequest = nil
    grace.cancel()
    echoes.cancelAll()
    lastOverrideTime = nil
  }

  public func resume() {
    suspended = false
    guard hasObservation, observationFailure == nil else { return }
    // Changes made while observation was suspended form a fresh OS baseline, not invented hotplug intent.
    intendedDefaultUID = observedDefaultUID.flatMap { availableUIDs.contains($0) ? $0 : nil }
  }

  private func highestPriority() -> String? {
    DevicePrioritySelection.highestPriority(
      availableUIDs: availableUIDs, priorityOrder: settings.devicePriorityOrder)
  }

  private func restoreIntendedDefault() throws {
    if let intendedDefaultUID, availableUIDs.contains(intendedDefaultUID) {
      try request(intendedDefaultUID)
    } else if let target = highestPriority() {
      try request(target)
    }
  }

  private func failExplicitSelection() {
    // Keep an actual writer error rather than replacing its detail with a settling diagnostic.
    guard operationFailure == nil || operationFailure == Self.selectionNotRetained else { return }
    recordFailure(Self.selectionNotRetained)
  }

  @discardableResult
  private func request(_ uid: String, force: Bool = false) throws -> UInt64 {
    guard !suspended, hasObservation, observationFailure == nil, availableUIDs.contains(uid) else {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "output-selection",
        message: "The requested output is not in a healthy current observation: \(uid).")
    }
    requestRevision &+= 1
    let revision = requestRevision
    if observedDefaultUID == uid, pendingDefaultUID == nil || pendingDefaultUID == uid {
      acceptedRequestRevision = revision
      intendedDefaultUID = uid
      operationFailure = nil
      return revision
    }
    if !force, pendingDefaultUID == uid { return revision }
    let token = echoes.reserve(uid)
    let priorPending = pendingRequest
    let priorFailureRevision = failureRevision
    pendingRequest = PendingRequest(uid: uid, token: token)
    do {
      try setDefaultOutput(uid)
      if revision > acceptedRequestRevision {
        acceptedRequestRevision = revision
        intendedDefaultUID = uid
        if failureRevision == priorFailureRevision { operationFailure = nil }
      }
    } catch {
      echoes.cancel(token)
      if pendingRequest?.token == token { pendingRequest = priorPending }
      throw error
    }
    return revision
  }

  private func recordFailure(_ error: any Error) {
    failureRevision &+= 1
    operationFailure =
      error as? AudioRouteFailure
      ?? AudioRouteFailure(stage: "output-write", message: String(describing: error))
  }
}
