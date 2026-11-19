import FineTuneDomain
import Observation

/// Saved input intent, last-good discovery and requested OS effects are separate values.
/// Root supplies all transport flags from the same healthy device snapshot and owns observers.
@Observable @MainActor
public final class InputDevicePolicyController {
  private let settings: any InputDevicePolicySettingsStore
  private let setDefaultInput: @MainActor (String) throws -> Void
  private let grace: DeviceAutoSwitchGrace
  public private(set) var availableUIDs: [String] = []
  public private(set) var observedDefaultUID: String?
  public private(set) var pendingDefaultUID: String?
  public private(set) var observationFailure: AudioRouteFailure?
  public private(set) var operationFailure: AudioRouteFailure?
  public var graceConnectionUID: String? { grace.uid }
  public var graceDuration: Duration? { grace.duration }
  private var builtInUIDs: Set<String> = []
  private var bluetoothUIDs: Set<String> = []
  private var hasObservation = false
  private var suspended = false
  private var previousLockEnabled: Bool
  private var previousPriority: [String]
  /// The connect-episode device this controller already corrected once; further OS re-assertions
  /// of the same device are deferred to instead of fought. Reset when a new episode starts.
  private var restoredConnectedUID: String?

  public init(
    settings: any InputDevicePolicySettingsStore,
    setDefaultInput: @escaping @MainActor (String) throws -> Void,
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.settings = settings
    self.setDefaultInput = setDefaultInput
    grace = DeviceAutoSwitchGrace(sleep: sleep)
    previousLockEnabled = settings.appSettings.lockInputDevice
    previousPriority = settings.inputDevicePriorityOrder
    grace.onFailure = { [weak self] error in
      guard let self else { return }
      self.operationFailure = self.routeFailure(error)
    }
  }

  isolated deinit { grace.cancel() }

  public var lastFailure: AudioRouteFailure? { observationFailure ?? operationFailure }

  /// Successful UID enumeration is already alive/eligible. A failed enumeration is not an empty one.
  public func observe(
    availableUIDs: [String], defaultUID: String?, builtInUIDs: Set<String>,
    bluetoothUIDs: Set<String>, failure: String? = nil
  ) {
    if let failure {
      observationFailure = AudioRouteFailure(stage: "input-observation", message: failure)
      return
    }
    let current = Set(availableUIDs)
    guard current.count == availableUIDs.count, !current.contains(""),
      builtInUIDs.isSubset(of: current), bluetoothUIDs.isSubset(of: current),
      builtInUIDs.isDisjoint(with: bluetoothUIDs)
    else {
      observationFailure = AudioRouteFailure(
        kind: .bindingChanged, stage: "input-observation",
        message: "Input observation contains invalid or inconsistent UID bindings.")
      return
    }
    let initialized = hasObservation
    let removed = Set(self.availableUIDs).subtracting(current)
    let connected = availableUIDs.filter { !self.availableUIDs.contains($0) }
    let oldDefault = observedDefaultUID
    self.availableUIDs = availableUIDs
    self.builtInUIDs = builtInUIDs
    self.bluetoothUIDs = bluetoothUIDs
    observedDefaultUID = defaultUID
    hasObservation = true
    observationFailure = nil
    if defaultUID == pendingDefaultUID || oldDefault != defaultUID { pendingDefaultUID = nil }
    guard !suspended else { return }
    do {
      if settings.appSettings.lockInputDevice,
        let preferred = settings.preferredInputDeviceUID, current.contains(preferred),
        !initialized || connected.contains(preferred)
      {
        settings.setLockedInputDeviceUID(preferred)
      }
      // A connect batch starts a fresh episode: enforce the lock or fallback once, then defer
      // further OS re-assertions of the same device instead of fighting them.
      let connectedDevice = connected.first
      if !connected.isEmpty { restoredConnectedUID = nil }
      let defaultChanged = oldDefault != defaultUID
      let removalFallback =
        oldDefault.map(removed.contains) == true
        || settings.lockedInputDeviceUID.map(removed.contains) == true
      let episodeCorrection =
        initialized && defaultChanged && defaultUID == connectedDevice
        && restoredConnectedUID != defaultUID
      if !connected.isEmpty || removalFallback || episodeCorrection {
        try reconcile(removed: removed, oldDefault: oldDefault)
        if defaultChanged, defaultUID == connectedDevice { restoredConnectedUID = defaultUID }
      }
      if initialized, settings.appSettings.lockInputDevice, let newUID = connected.first {
        grace.start(uid: newUID, bluetooth: bluetoothUIDs.contains(newUID))
      } else if let grace = graceConnectionUID, removed.contains(grace) {
        self.grace.cancel()
      }
      if initialized, connected.isEmpty, let grace = graceConnectionUID,
        oldDefault != defaultUID, defaultUID == grace, settings.appSettings.lockInputDevice
      {
        self.grace.start(uid: grace, bluetooth: bluetoothUIDs.contains(grace))
      }
    } catch { operationFailure = routeFailure(error) }
  }

  /// Explicit selection saves both user preference and current lock even when a native write fails.
  public func selectPreferredInput(uid: String) throws {
    guard !uid.isEmpty else {
      throw AudioRouteFailure(
        kind: .unsupported, stage: "input-selection", message: "Input UID is empty.")
    }
    settings.setPreferredInputDeviceUID(uid)
    settings.setLockedInputDeviceUID(uid)
    pendingDefaultUID = nil
    do { try request(uid) } catch {
      operationFailure = routeFailure(error)
      throw error
    }
  }

  public func settingsDidChange() {
    let enabled = settings.appSettings.lockInputDevice
    let priorityChanged = previousPriority != settings.inputDevicePriorityOrder
    if enabled, !previousLockEnabled, observationFailure == nil,
      let current = observedDefaultUID, availableUIDs.contains(current)
    {
      settings.setLockedInputDeviceUID(current)
      settings.setPreferredInputDeviceUID(current)
    }
    previousLockEnabled = enabled
    previousPriority = settings.inputDevicePriorityOrder
    if !enabled { self.grace.cancel() }
    // Priority reordering while unlocked is the only settings-driven enforcement; plain
    // settings changes never chase the observed default.
    guard !suspended, hasObservation, observationFailure == nil, !enabled, priorityChanged,
      let target = DevicePrioritySelection.highestPriority(
        availableUIDs: availableUIDs, priorityOrder: settings.inputDevicePriorityOrder)
    else { return }
    do {
      pendingDefaultUID = nil
      try request(target)
    } catch { operationFailure = routeFailure(error) }
  }

  public func suspend() {
    suspended = true
    pendingDefaultUID = nil
    restoredConnectedUID = nil
    self.grace.cancel()
  }

  public func resume() {
    suspended = false
    guard hasObservation, observationFailure == nil else { return }
    if settings.appSettings.lockInputDevice, let preferred = settings.preferredInputDeviceUID,
      availableUIDs.contains(preferred)
    {
      settings.setLockedInputDeviceUID(preferred)
    }
    do { try reconcile(removed: [], oldDefault: observedDefaultUID) } catch {
      operationFailure = routeFailure(error)
    }
  }

  private func reconcile(removed: Set<String>, oldDefault: String?) throws {
    guard hasObservation, observationFailure == nil, !suspended else { return }
    if settings.appSettings.lockInputDevice {
      let target: String?
      if let locked = settings.lockedInputDeviceUID, availableUIDs.contains(locked) {
        target = locked
      } else if let locked = settings.lockedInputDeviceUID, removed.contains(locked) {
        target = DevicePrioritySelection.highestPriority(
          availableUIDs: availableUIDs, priorityOrder: settings.inputDevicePriorityOrder)
      } else {
        target = availableUIDs.first(where: builtInUIDs.contains)
      }
      guard let target else {
        throw AudioRouteFailure(
          kind: .unavailable, stage: "input-lock",
          message: "The locked input and a confirmed fallback are unavailable.")
      }
      if settings.lockedInputDeviceUID != target { settings.setLockedInputDeviceUID(target) }
      try request(target)
    } else if let oldDefault, removed.contains(oldDefault),
      let target = DevicePrioritySelection.highestPriority(
        availableUIDs: availableUIDs, priorityOrder: settings.inputDevicePriorityOrder)
    {
      try request(target)
    }
  }

  private func request(_ uid: String) throws {
    guard hasObservation, observationFailure == nil, !suspended, availableUIDs.contains(uid) else {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "input-selection",
        message: "The requested input is not in a healthy current observation: \(uid).")
    }
    if observedDefaultUID == uid {
      pendingDefaultUID = nil
      operationFailure = nil
      return
    }
    if pendingDefaultUID == uid { return }
    pendingDefaultUID = uid
    do {
      try setDefaultInput(uid)
      operationFailure = nil
    } catch {
      pendingDefaultUID = nil
      throw error
    }
  }

  private func routeFailure(_ error: any Error) -> AudioRouteFailure {
    error as? AudioRouteFailure
      ?? AudioRouteFailure(stage: "input-write", message: String(describing: error))
  }
}
