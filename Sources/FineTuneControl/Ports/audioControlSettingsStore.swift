import FineTuneDomain

/// Saved preferences. The existing platform settings object supplies these without a second mirror.
@MainActor
public protocol AudioControlSettingsStore: AppAudioSettingsStore, AutoEQPreferencesReading {
  func updateAppSettings(_ settings: AppSettings)
  func resetAllSettings()
  func getDeviceRouting(for identifier: String) -> String?
  func setDeviceRouting(for identifier: String, deviceUID: String)
  func isFollowingDefault(for identifier: String) -> Bool
  func setFollowDefault(for identifier: String)
  func getEQSettings(for identifier: String) -> EQSettings
  func setEQSettings(_ settings: EQSettings, for identifier: String)
  func isPinned(_ identifier: String) -> Bool
  func isIgnored(_ identifier: String) -> Bool
  func setAppPinned(_ identifier: String, pinned: Bool, displayName: String?, bundleID: String?)
    throws
  func setAppIgnored(_ identifier: String, ignored: Bool, displayName: String?, bundleID: String?)
    throws
  func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?)
  var autoEQPreampEnabled: Bool { get set }
  func setAutoEQFavorite(profileID: String, favorite: Bool)
  var devicePriorityOrder: [String] { get }
}
