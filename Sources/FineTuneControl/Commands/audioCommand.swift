import FineTuneDomain

/// Normalized user operations. Applying these to desired/store state is synchronous.
public enum AudioCommand: Equatable, Sendable {
  case setGain(identifier: String, gain: Float)
  /// A UI slider edit also unmutes, without changing the independent boost.
  case editGain(identifier: String, gain: Float)
  case setMuted(identifier: String, muted: Bool)
  case toggleMuted(identifier: String)
  case setBoost(identifier: String, boost: BoostLevel)
  case setEQ(identifier: String, settings: EQSettings)
  case followDefault(identifier: String)
  case setRoute(identifier: String, mode: DeviceSelectionMode, uids: Set<String>)
  case setPinned(identifier: String, pinned: Bool)
  case setIgnored(identifier: String, ignored: Bool)
  case stepVolume(identifier: String, isUp: Bool, shift: Bool)
  /// URL-only slider delta. Active targets only; mute is unchanged.
  case stepSlider(identifier: String, delta: Float)
  /// URL-only single-output selection. Inactive targets are unchanged.
  case setOutputDevice(identifier: String, uid: String)
  /// nil resets all active targets; an explicit identity also saves inactive preferences.
  case resetGainAndMute(identifier: String?)
  /// Only the confirmed reset UI dispatches this destructive preference operation.
  case resetAllSettings
  case updateAppSettings(AppSettings)
  case setAutoEQSelection(deviceUID: String, selection: AutoEQSelection?)
  case setAutoEQPreampEnabled(Bool)
  case setAutoEQFavorite(profileID: String, favorite: Bool)
  case profileAvailabilityChanged(profileID: String)
  case requestCaptureStart
  case stopCapture
  case setDefaultDevice(scope: AudioDeviceScope, uid: String)
  /// UI editing applies the gain and unmutes the device.
  case setDeviceGain(scope: AudioDeviceScope, uid: String, gain: Float)
  /// Raw/media gain changes preserve the independent mute state.
  case setRawDeviceGain(scope: AudioDeviceScope, uid: String, gain: Float)
  case setDeviceMuted(scope: AudioDeviceScope, uid: String, muted: Bool)
  case stepDeviceVolume(scope: AudioDeviceScope, uid: String, isUp: Bool, shift: Bool)
  case setDeviceHidden(scope: AudioDeviceScope, uid: String, hidden: Bool)
  case setDevicePriority(scope: AudioDeviceScope, connectedUIDs: [String])
  case setDeviceIcon(uid: String, symbol: String?)
  case setDeviceVolumeOverride(uid: String, tier: VolumeControlTier?)
}

/// The command handler owns asynchronous native effects after synchronous desired-state mutation.
@MainActor
public protocol AudioCommandHandling: AnyObject {
  func perform(_ command: AudioCommand)
}
