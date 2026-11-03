import Foundation
import Observation

@MainActor @Observable
public final class DDCVolumeBackend: DDCVolumeControlling {
  public private(set) var states: [String: DDCVolumeState] = [:]
  public private(set) var unavailableReasons: [String: String] = [:]
  public private(set) var lastError: (any Error)?
  public private(set) var isRunning = false
  public private(set) var isProbing = false
  @ObservationIgnored public var onChange: (() -> Void)?
  private let transport: any DDCDisplayTransport
  private let preferences: any DDCPreferenceStoring
  private let candidates: @MainActor () throws -> [DDCAudioCandidate]
  private let displayChanges: any DisplayParameterObserving
  private let clock: DeviceBackendClock
  @ObservationIgnored private var observation: DevicePropertyObservation?
  @ObservationIgnored private var probeTask: Task<Void, Never>?
  @ObservationIgnored private var writes: [String: PendingDDCWrite] = [:]
  @ObservationIgnored private var bindings: [String: UUID] = [:]
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var probeGeneration: UInt64 = 0
  @ObservationIgnored private var lastErrorUID: String?

  public init(
    transport: any DDCDisplayTransport, preferences: any DDCPreferenceStoring,
    candidates: @escaping @MainActor () throws -> [DDCAudioCandidate],
    displayChanges: any DisplayParameterObserving, clock: DeviceBackendClock
  ) {
    self.transport = transport
    self.preferences = preferences
    self.candidates = candidates
    self.displayChanges = displayChanges
    self.clock = clock
  }

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    let epoch = generation
    observation = displayChanges.observe { [weak self] in
      guard let self, self.isRunning, self.generation == epoch else { return }
      self.devicesDidChange()
    }
    scheduleProbe(after: .zero)
  }

  /// CoreAudio topology and screen-parameter changes invalidate old identity bindings immediately.
  public func devicesDidChange() {
    guard isRunning else { return }
    scheduleProbe(after: .seconds(3))
  }

  public func stop() async {
    isRunning = false
    generation &+= 1
    probeGeneration &+= 1
    let epoch = generation
    probeTask?.cancel()
    probeTask = nil
    observation?.cancel()
    observation = nil
    cancelWrites()
    bindings.removeAll()
    states.removeAll()
    unavailableReasons.removeAll()
    isProbing = false
    onChange?()
    do {
      try await transport.close()
    } catch {
      guard generation == epoch else { return }
      lastError = error
      lastErrorUID = nil
      onChange?()
    }
  }

  isolated deinit {
    observation?.cancel()
    probeTask?.cancel()
    for write in writes.values { write.task.cancel() }
    // The live transport's own destructor also serializes final CF/image cleanup.
  }

  public func probe() async {
    guard isRunning else { return }
    probeTask?.cancel()
    let ticket = beginProbe()
    await performProbe(ticket: ticket, epoch: generation)
  }

  public func requestVolume(forUID uid: String, to volume: Float) throws {
    do {
      guard volume.isFinite, (0...1).contains(volume) else {
        throw DeviceBackendError.invalidVolume(volume)
      }
      _ = try currentBinding(for: uid)
      let percent = Int((volume * 100).rounded())
      preferences.setDDCVolume(for: uid, to: percent)
      if preferences.getDDCMuteState(for: uid) {
        // Editing an explicitly muted wish does not pretend the physical VCP changed from zero.
        preferences.setDDCSavedVolume(for: uid, to: percent)
        states[uid]?.requestedPercent = percent
        onChange?()
      } else {
        try scheduleWrite(for: uid, percent: percent)
      }
    } catch {
      record(error, for: uid)
      throw error
    }
  }

  public func requestMute(forUID uid: String, to muted: Bool) throws {
    do {
      _ = try currentBinding(for: uid)
      guard let state = states[uid] else { throw DeviceBackendError.unavailableDevice(uid) }
      let desiredMute = preferences.getDDCMuteState(for: uid)
      if muted {
        if desiredMute && state.isMuted { return }
        let restore =
          (desiredMute ? preferences.getDDCSavedVolume(for: uid) : nil)
          ?? state.requestedPercent ?? state.observedPercent
        guard let restore else {
          throw DeviceBackendError.unsupported("A known pre-mute DDC volume")
        }
        try validatePercent(restore)
        if restore > 0 || preferences.getDDCSavedVolume(for: uid) == nil {
          preferences.setDDCSavedVolume(for: uid, to: restore)
        }
        preferences.setDDCMuteState(for: uid, to: true)
        preferences.flushSync()
        if let error = preferences.lastSaveError {
          throw DeviceBackendError.operationFailed(
            "The pre-mute display volume could not be saved: \(error)")
        }
        try scheduleWrite(for: uid, percent: 0)
      } else {
        if !desiredMute && !state.isMuted { return }
        let restore =
          state.requestedPercent ?? preferences.getDDCSavedVolume(for: uid)
          ?? preferences.getDDCVolume(for: uid) ?? state.observedPercent
        guard let restore else {
          throw DeviceBackendError.unsupported("A known DDC restore volume")
        }
        try validatePercent(restore)
        preferences.setDDCMuteState(for: uid, to: false)
        preferences.setDDCVolume(for: uid, to: restore)
        try scheduleWrite(for: uid, percent: restore)
      }
    } catch {
      record(error, for: uid)
      throw error
    }
  }

  private func scheduleProbe(after delay: Duration) {
    probeTask?.cancel()
    let ticket = beginProbe()
    let epoch = generation
    let clock = clock
    probeTask = Task { [weak self] in
      do {
        if delay > .zero { try await clock.sleep(delay) }
        try Task.checkCancellation()
        await self?.performProbe(ticket: ticket, epoch: epoch)
      } catch {
        self?.probeFailed(error, ticket: ticket, epoch: epoch)
      }
    }
  }

  private func beginProbe() -> UInt64 {
    probeGeneration &+= 1
    cancelWrites()
    bindings.removeAll()
    isProbing = true
    for uid in states.keys {
      states[uid] = DDCVolumeState(
        observedPercent: nil, requestedPercent: preferences.getDDCSavedVolume(for: uid),
        isMuted: false, isApplying: false, error: "Checking the display's DDC connection.")
    }
    onChange?()
    return probeGeneration
  }

  private func performProbe(ticket: UInt64, epoch: UInt64) async {
    guard isRunning, generation == epoch, probeGeneration == ticket else { return }
    do {
      let initial = try candidates()
      let displays: [DDCDisplaySnapshot]
      if initial.contains(where: { DDCDeviceMatcher.eligible($0.transport) }) {
        displays = try await transport.discover()
      } else {
        try await transport.close()
        displays = []
      }
      try Task.checkCancellation()
      guard isRunning, generation == epoch, probeGeneration == ticket else { return }
      let current = try candidates()
      let matches = DDCDeviceMatcher.match(candidates: current, displays: displays)
      let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
      var next: [String: DDCVolumeState] = [:]
      for candidate in current {
        let uid = candidate.uid
        if let displayID = matches.bindings[uid], let reading = byID[displayID]?.volume {
          next[uid] = DDCVolumeState(
            observedPercent: try DDCVolumeScale.percent(of: reading), requestedPercent: nil,
            isMuted: false, isApplying: false, error: nil)
        } else if states[uid] != nil {
          // Keep previously known DDC capability unavailable rather than silently changing its tier.
          next[uid] = DDCVolumeState(
            observedPercent: nil, requestedPercent: preferences.getDDCSavedVolume(for: uid),
            isMuted: false, isApplying: false, error: matches.unavailable[uid]?.localizedDescription
          )
        }
      }
      states = next
      bindings = matches.bindings
      unavailableReasons = matches.unavailable.mapValues(\.localizedDescription)
      isProbing = false
      lastError = nil
      lastErrorUID = nil
      onChange?()
      for uid in Array(bindings.keys) {
        do {
          if preferences.getDDCMuteState(for: uid) {
            try requestMute(forUID: uid, to: true)
          } else if let saved = preferences.getDDCVolume(for: uid),
            saved != states[uid]?.observedPercent
          {
            try validatePercent(saved)
            try requestVolume(forUID: uid, to: Float(saved) / 100)
          }
        } catch {
          record(error, for: uid)
        }
      }
    } catch {
      probeFailed(error, ticket: ticket, epoch: epoch)
    }
  }

  private func probeFailed(_ error: any Error, ticket: UInt64, epoch: UInt64) {
    guard isRunning, generation == epoch, probeGeneration == ticket else { return }
    isProbing = false
    lastError = error
    lastErrorUID = nil
    for uid in states.keys { states[uid]?.error = error.localizedDescription }
    onChange?()
  }

  private func currentBinding(for uid: String) throws -> UUID {
    guard isRunning, !isProbing, let displayID = bindings[uid], states[uid]?.observedPercent != nil,
      try candidates().contains(where: { $0.uid == uid })
    else {
      throw DeviceBackendError.operationFailed(
        unavailableReasons[uid] ?? "The selected device's DDC display is not currently available.")
    }
    return displayID
  }

  private func scheduleWrite(for uid: String, percent: Int) throws {
    let displayID = try currentBinding(for: uid)
    try validatePercent(percent)
    if writes[uid]?.percent == percent { return }
    let previous = writes.removeValue(forKey: uid)
    previous?.task.cancel()
    // Cancelling an issued blocking call cannot undo its physical side effect.
    if previous?.hasIssued != true, states[uid]?.observedPercent == percent,
      states[uid]?.isMuted == preferences.getDDCMuteState(for: uid)
    {
      if var state = states[uid] {
        state.isApplying = false
        state.requestedPercent = state.isMuted ? preferences.getDDCSavedVolume(for: uid) : nil
        states[uid] = state
      }
      clearError(for: uid)
      onChange?()
      return
    }
    let token = UUID()
    let epoch = generation
    let probe = probeGeneration
    states[uid]?.requestedPercent =
      preferences.getDDCMuteState(for: uid)
      ? preferences.getDDCSavedVolume(for: uid) : percent
    states[uid]?.isApplying = true
    states[uid]?.error = nil
    let clock = clock
    let transport = transport
    let task = Task { [weak self] in
      do {
        try await clock.sleep(.milliseconds(100))
        try Task.checkCancellation()
        try self?.beginWrite(
          uid: uid, token: token, displayID: displayID, epoch: epoch, probe: probe)
        guard self != nil else { return }
        let reading = try await transport.writeVolume(displayID: displayID, percent: percent)
        try Task.checkCancellation()
        try self?.completeWrite(
          reading, uid: uid, token: token, displayID: displayID, epoch: epoch, probe: probe)
      } catch {
        self?.writeFailed(error, uid: uid, token: token)
      }
    }
    writes[uid] = PendingDDCWrite(token: token, percent: percent, task: task)
    onChange?()
  }

  private func beginWrite(uid: String, token: UUID, displayID: UUID, epoch: UInt64, probe: UInt64)
    throws
  {
    try validateWrite(uid: uid, token: token, displayID: displayID, epoch: epoch, probe: probe)
    writes[uid]?.hasIssued = true
  }

  private func validateWrite(
    uid: String, token: UUID, displayID: UUID, epoch: UInt64, probe: UInt64
  ) throws {
    guard isRunning, generation == epoch, probeGeneration == probe, writes[uid]?.token == token,
      try currentBinding(for: uid) == displayID
    else { throw CancellationError() }
  }

  private func completeWrite(
    _ reading: DDCVCPValue, uid: String, token: UUID, displayID: UUID, epoch: UInt64, probe: UInt64
  ) throws {
    try validateWrite(uid: uid, token: token, displayID: displayID, epoch: epoch, probe: probe)
    guard let pending = writes[uid], var state = states[uid] else { return }
    let observed: Int
    do {
      observed = try DDCVolumeScale.percent(of: reading)
    } catch {
      bindings.removeValue(forKey: uid)
      states[uid]?.observedPercent = nil
      states[uid]?.isMuted = false
      unavailableReasons[uid] = error.localizedDescription
      throw error
    }
    writes.removeValue(forKey: uid)
    state.observedPercent = observed
    state.isApplying = false
    state.isMuted = preferences.getDDCMuteState(for: uid) && pending.percent == 0 && observed == 0
    if observed == pending.percent {
      state.requestedPercent = state.isMuted ? preferences.getDDCSavedVolume(for: uid) : nil
      state.error = nil
      clearError(for: uid)
    } else {
      let error = DeviceBackendError.operationFailed(
        "The display did not confirm the requested volume.")
      state.error = error.localizedDescription
      lastError = error
      lastErrorUID = uid
    }
    states[uid] = state
    onChange?()
  }

  private func writeFailed(_ error: any Error, uid: String, token: UUID) {
    guard writes[uid]?.token == token else { return }
    writes.removeValue(forKey: uid)
    states[uid]?.isApplying = false
    record(error, for: uid)
  }

  private func cancelWrites() {
    let pending = writes.values
    writes.removeAll()
    for write in pending { write.task.cancel() }
  }

  private func record(_ error: any Error, for uid: String) {
    states[uid]?.error = error.localizedDescription
    lastError = error
    lastErrorUID = uid
    onChange?()
  }

  private func clearError(for uid: String) {
    states[uid]?.error = nil
    if lastErrorUID == uid {
      lastError = nil
      lastErrorUID = nil
    }
  }

  private func validatePercent(_ percent: Int) throws {
    guard (0...100).contains(percent) else {
      throw DeviceBackendError.invalidVolume(Float(percent) / 100)
    }
  }
}

private struct PendingDDCWrite {
  let token: UUID
  let percent: Int
  let task: Task<Void, Never>
  var hasIssued = false
}
