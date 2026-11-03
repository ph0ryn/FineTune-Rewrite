import AudioToolbox
import FineTuneControl
import FineTuneDomain

@MainActor
public protocol AudioDeviceProviding: AnyObject {
  var outputDevices: [AudioDevice] { get }
  var inputDevices: [AudioDevice] { get }
  var onDeviceDisconnected: ((String, String) -> Void)? { get set }
  var onDeviceConnected: ((String, String) -> Void)? { get set }
  var onInputDeviceDisconnected: ((String, String) -> Void)? { get set }
  var onInputDeviceConnected: ((String, String) -> Void)? { get set }
  func device(for uid: String) -> AudioDevice?
  func inputDevice(for uid: String) -> AudioDevice?
  func start()
  func stop()
}

@MainActor
public protocol AudioProcessMonitoring: AnyObject {
  var activeApps: [AudioApp] { get }
  var onAppsChanged: (([AudioApp]) -> Void)? { get set }
  func start()
  func stop()
}

/// Platform-only OS identity around the OS-independent runtime-control port.
@MainActor
public protocol ProcessTapControlling: AudioRouteControlling {
  var app: AudioApp { get }
  var currentDeviceUIDs: [String] { get }
  var currentDeviceUID: String? { get }
}

@MainActor
public protocol DeviceVolumeProviding: AnyObject {
  var defaultDeviceID: AudioDeviceID { get }
  var defaultDeviceUID: String? { get }
  var defaultInputDeviceUID: String? { get }
  var volumes: [AudioDeviceID: Float] { get }
  var muteStates: [AudioDeviceID: Bool] { get }
  var onVolumeChanged: ((AudioDeviceID, Float) -> Void)? { get set }
  var onMuteChanged: ((AudioDeviceID, Bool) -> Void)? { get set }
  var onDefaultDeviceChanged: ((String) -> Void)? { get set }
  var onDefaultInputDeviceChanged: ((String) -> Void)? { get set }
  @discardableResult func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool
  @discardableResult func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool
  func setVolume(for deviceID: AudioDeviceID, to volume: Float)
  func setMute(for deviceID: AudioDeviceID, to muted: Bool)
  func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier
  func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier
  func outputProcessingGain(for deviceID: AudioDeviceID) -> Float
  func refreshOutputDeviceStates()
  func applyTierOverrideChange(for deviceID: AudioDeviceID)
  func start()
  func stop()
  func refreshAfterDDCProbe()
}

extension DeviceVolumeProviding {
  public func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
    outputVolumeBackend(for: deviceID)
  }
  public func outputProcessingGain(for deviceID: AudioDeviceID) -> Float {
    outputVolumeBackend(for: deviceID) == .software ? volumes[deviceID] ?? 1 : 1
  }
  public func refreshOutputDeviceStates() {}
  public func applyTierOverrideChange(for deviceID: AudioDeviceID) { refreshOutputDeviceStates() }
  public func refreshAfterDDCProbe() { refreshOutputDeviceStates() }
}
