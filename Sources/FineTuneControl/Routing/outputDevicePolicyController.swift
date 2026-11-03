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
  public private(set) var pendingDefaultUID: String?
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
    echoes.onTimeout = { [weak self] uid in
      guard let self, !self.suspended, self.observationFailure == nil else { return }
      if self.pendingDefaultUID == uid { self.pendingDefaultUID = nil }
      do { try self.restoreIntendedDefault() } catch { self.recordFailure(error) }
    }
  }

  isolated deinit {
    grace.cancel()
    echoes.cancelAll()
  }

  public func observe(
    availableUIDs: [String], defaultUID: String?, bluetoothUIDs: Set<String>, failure: String? = nil
  ) {
    if let failure {
      observationFailure = AudioRouteFailure(stage: "output-observation", message: failure)
      return
    }
    let current = Set(availableUIDs)
    guard current.count == availableUIDs.count, !current.contains(""),
      bluetoothUIDs.isSubset(of: current)
    else {
      observationFailure = AudioRouteFailure(
        kind: .bindingChanged, stage: "output-observation",
        message: "Output observation contains invalid or inconsistent UID bindings.")
      return
    }
    let initialized = hasObservation
    let oldDefault = observedDefaultUID
    let removed = Set(self.availableUIDs).subtracting(current)
    let connected = current.subtracting(self.availableUIDs)
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
    if ownEcho, pendingDefaultUID == defaultUID { pendingDefaultUID = nil }
    do {
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
      guard current.contains(defaultUID), !echoes.hasPending else { return }
      grace.cancel()
      lastOverrideTime = nil
      intendedDefaultUID = defaultUID
    } catch { recordFailure(error) }
  }

  /// UI selection must enter here, so its acknowledgement is consumed before the auto-switch branch.
  public func selectDefaultOutput(uid: String) throws {
    do { try request(uid) } catch {
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
    do { try request(target) } catch { recordFailure(error) }
  }

  public func suspend() {
    suspended = true
    pendingDefaultUID = nil
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

  private func request(_ uid: String) throws {
    guard !suspended, hasObservation, observationFailure == nil, availableUIDs.contains(uid) else {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "output-selection",
        message: "The requested output is not in a healthy current observation: \(uid).")
    }
    if observedDefaultUID == uid, pendingDefaultUID == nil || pendingDefaultUID == uid {
      intendedDefaultUID = uid
      operationFailure = nil
      return
    }
    if pendingDefaultUID == uid, echoes.hasPending { return }
    let token = echoes.reserve(uid)
    let priorPending = pendingDefaultUID
    pendingDefaultUID = uid
    do {
      try setDefaultOutput(uid)
      intendedDefaultUID = uid
      operationFailure = nil
    } catch {
      echoes.cancel(token)
      pendingDefaultUID = priorPending
      throw error
    }
  }

  private func recordFailure(_ error: any Error) {
    operationFailure =
      error as? AudioRouteFailure
      ?? AudioRouteFailure(stage: "output-write", message: String(describing: error))
  }
}
