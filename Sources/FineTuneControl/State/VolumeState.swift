import FineTuneDomain
import Observation

/// Runtime app state keyed by process number, with persistence addressed separately by app identity.
@Observable
@MainActor
public final class VolumeState {
  private struct State {
    var identifier: String
    var volume: Float
    var muted = false
    var boost: BoostLevel = .x1
    var mode: DeviceSelectionMode = .single
    var selectedDevices: Set<String> = []
  }

  private var states: [Int32: State] = [:]
  private let settingsManager: (any AppAudioSettingsStore)?

  public init(settingsManager: (any AppAudioSettingsStore)? = nil) {
    self.settingsManager = settingsManager
  }

  private var defaultVolume: Float { settingsManager?.appSettings.defaultNewAppVolume ?? 1 }

  public func getVolume(for process: Int32) -> Float { states[process]?.volume ?? defaultVolume }
  public func getMute(for process: Int32) -> Bool { states[process]?.muted ?? false }
  public func getBoost(for process: Int32) -> BoostLevel { states[process]?.boost ?? .x1 }
  public func getDeviceSelectionMode(for process: Int32) -> DeviceSelectionMode {
    states[process]?.mode ?? .single
  }
  public func getSelectedDeviceUIDs(for process: Int32) -> Set<String> {
    states[process]?.selectedDevices ?? []
  }

  public func setVolume(for process: Int32, to volume: Float, identifier: String? = nil) {
    update(process, identifier: identifier) {
      $0.volume = volume
    } save: { store, state in
      store.setVolume(for: state.identifier, to: state.volume)
    }
  }

  public func setMute(for process: Int32, to muted: Bool, identifier: String? = nil) {
    update(process, identifier: identifier) {
      $0.muted = muted
    } save: { store, state in
      store.setMute(for: state.identifier, to: state.muted)
    }
  }

  public func setBoost(for process: Int32, to boost: BoostLevel, identifier: String? = nil) {
    update(process, identifier: identifier) {
      $0.boost = boost
    } save: { store, state in
      store.setBoost(for: state.identifier, to: state.boost)
    }
  }

  public func setDeviceSelectionMode(
    for process: Int32, to mode: DeviceSelectionMode, identifier: String? = nil
  ) {
    update(process, identifier: identifier) {
      $0.mode = mode
    } save: { store, state in
      store.setDeviceSelectionMode(for: state.identifier, to: state.mode)
    }
  }

  public func setSelectedDeviceUIDs(
    for process: Int32, to uids: Set<String>, identifier: String? = nil
  ) {
    update(process, identifier: identifier) {
      $0.selectedDevices = uids
    } save: { store, state in
      store.setSelectedDeviceUIDs(for: state.identifier, to: state.selectedDevices)
    }
  }

  @discardableResult
  public func loadSavedVolume(for process: Int32, identifier: String) -> Float? {
    ensureState(process, identifier: identifier)
    guard let volume = settingsManager?.getVolume(for: identifier) else { return nil }
    states[process]?.volume = volume
    return volume
  }

  @discardableResult
  public func loadSavedMute(for process: Int32, identifier: String) -> Bool? {
    ensureState(process, identifier: identifier)
    guard let muted = settingsManager?.getMute(for: identifier) else { return nil }
    states[process]?.muted = muted
    return muted
  }

  @discardableResult
  public func loadSavedBoost(for process: Int32, identifier: String) -> BoostLevel? {
    ensureState(process, identifier: identifier)
    guard let boost = settingsManager?.getBoost(for: identifier) else { return nil }
    states[process]?.boost = boost
    return boost
  }

  @discardableResult
  public func loadSavedDeviceSelectionMode(
    for process: Int32, identifier: String
  ) -> DeviceSelectionMode? {
    ensureState(process, identifier: identifier)
    guard let mode = settingsManager?.getDeviceSelectionMode(for: identifier) else { return nil }
    states[process]?.mode = mode
    return mode
  }

  @discardableResult
  public func loadSavedSelectedDeviceUIDs(for process: Int32, identifier: String) -> Set<String>? {
    ensureState(process, identifier: identifier)
    guard let devices = settingsManager?.getSelectedDeviceUIDs(for: identifier) else { return nil }
    states[process]?.selectedDevices = devices
    return devices
  }

  public func removeVolume(for process: Int32) { states.removeValue(forKey: process) }
  public func cleanup(keeping processes: Set<Int32>) {
    states = states.filter { processes.contains($0.key) }
  }
  public func resetAll() { states.removeAll() }

  private func ensureState(_ process: Int32, identifier: String) {
    if states[process] == nil {
      states[process] = State(identifier: identifier, volume: defaultVolume)
    }
    states[process]?.identifier = identifier
  }

  private func update(
    _ process: Int32, identifier: String?, change: (inout State) -> Void,
    save: (any AppAudioSettingsStore, State) -> Void
  ) {
    guard
      var state = states[process]
        ?? identifier.map({ State(identifier: $0, volume: defaultVolume) })
    else { return }
    if let identifier { state.identifier = identifier }
    change(&state)
    states[process] = state
    if let settingsManager { save(settingsManager, state) }
  }
}
