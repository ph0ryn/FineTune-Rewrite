import FineTuneDomain

/// The saved preferences needed by process state, independent of files and OS services.
@MainActor
public protocol AppAudioSettingsStore: AnyObject {
  var appSettings: AppSettings { get }
  func getVolume(for identifier: String) -> Float?
  func setVolume(for identifier: String, to volume: Float)
  func getMute(for identifier: String) -> Bool?
  func setMute(for identifier: String, to muted: Bool)
  func getBoost(for identifier: String) -> BoostLevel?
  func setBoost(for identifier: String, to boost: BoostLevel)
  func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode?
  func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode)
  func getSelectedDeviceUIDs(for identifier: String) -> Set<String>?
  func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>)
}
