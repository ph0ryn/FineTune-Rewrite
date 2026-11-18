import FineTuneControl
import FineTuneDomain

@MainActor
final class MutableBox<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// Pure in-memory store conforming to Control's persistence ports with zero disk I/O.
@MainActor
final class InMemoryControlSettingsStore: AudioControlSettingsStore,
  InputDevicePolicySettingsStore, OutputDevicePolicySettingsStore
{
  var appSettings: AppSettings
  var autoEQPreampEnabled = true
  var favoriteAutoEQProfileIDs: Set<String> = []
  var devicePriorityOrder: [String] = []
  var inputDevicePriorityOrder: [String] = []
  var preferredInputDeviceUID: String?
  var lockedInputDeviceUID: String?

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

  init(explicitUserCaptureEnabled: Bool = false) {
    var initial = AppSettings()
    initial.explicitUserCaptureEnabled = explicitUserCaptureEnabled
    self.appSettings = initial
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
  func setPreferredInputDeviceUID(_ uid: String?) { preferredInputDeviceUID = uid }
  func setLockedInputDeviceUID(_ uid: String?) { lockedInputDeviceUID = uid }
  func setDevicePriorityOrder(_ order: [String]) { devicePriorityOrder = order }
  func setInputDevicePriorityOrder(_ order: [String]) { inputDevicePriorityOrder = order }
  func ensureDeviceInPriority(_ uid: String) {
    guard !devicePriorityOrder.contains(uid) else { return }
    devicePriorityOrder.append(uid)
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
    preferredInputDeviceUID = nil
    lockedInputDeviceUID = nil
    autoEQPreampEnabled = true
  }
}
