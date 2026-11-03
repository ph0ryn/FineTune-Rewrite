import AudioToolbox
import FineTuneDomain
import Observation

/// Hardware property writes and software-gain preferences share a port, but never a volume curve.
@Observable
@MainActor
public final class CoreAudioDeviceVolumeAdapter: DeviceVolumeProviding {
  public enum AdapterError: Error {
    case unsupportedBackend(VolumeControlTier)
    case invalidVolume(Float)
  }

  public private(set) var defaultDeviceID: AudioDeviceID = .unknown
  public private(set) var defaultDeviceUID: String?
  public private(set) var defaultInputDeviceUID: String?
  public private(set) var volumes: [AudioDeviceID: Float] = [:]
  public private(set) var muteStates: [AudioDeviceID: Bool] = [:]
  public private(set) var lastError: Error?
  public var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
  public var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
  public var onDefaultDeviceChanged: ((String) -> Void)?
  public var onDefaultInputDeviceChanged: ((String) -> Void)?

  private let deviceProvider: any AudioDeviceProviding
  private let settings: SettingsManager
  private let detectBackend: @MainActor (AudioDeviceID) -> VolumeControlTier
  private var running = false
  private var listeners:
    [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

  public init(
    deviceProvider: any AudioDeviceProviding, settingsManager: SettingsManager,
    autoDetectedBackend: (@MainActor (AudioDeviceID) -> VolumeControlTier)? = nil
  ) {
    self.deviceProvider = deviceProvider
    self.settings = settingsManager
    self.detectBackend =
      autoDetectedBackend ?? { device in
        device.isPropertySettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
          ? .hardware : .software
      }
  }

  public func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
    if let device = deviceProvider.outputDevices.first(where: { $0.id == deviceID }),
      let tier = settings.getDeviceVolumeTierOverride(for: device.uid)
    {
      return tier
    }
    return autoDetectedOutputVolumeBackend(for: deviceID)
  }

  public func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
    detectBackend(deviceID)
  }

  public func outputProcessingGain(for deviceID: AudioDeviceID) -> Float {
    outputVolumeBackend(for: deviceID) == .software ? volumes[deviceID] ?? 1 : 1
  }

  public func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
    do {
      guard volume.isFinite, (0...1).contains(volume) else {
        throw AdapterError.invalidVolume(volume)
      }
      let tier = outputVolumeBackend(for: deviceID)
      let value = DeviceVolumePolicy.storedVolume(volume, tier: tier)
      switch tier {
      case .hardware:
        try AudioProperties.write(
          deviceID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
          scope: kAudioObjectPropertyScopeOutput, value: value
        )
      case .software:
        let uid = try deviceID.readDeviceUID()
        settings.setSoftwareDeviceVolume(for: uid, to: value)
        settings.setSoftwareDeviceSavedVolume(for: uid, to: value)
      case .ddc:
        throw AdapterError.unsupportedBackend(.ddc)
      }
      volumes[deviceID] = value
      lastError = nil
      onVolumeChanged?(deviceID, value)
    } catch { lastError = error }
  }

  public func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
    do {
      switch outputVolumeBackend(for: deviceID) {
      case .hardware:
        try AudioProperties.write(
          deviceID, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
          value: UInt32(muted ? 1 : 0)
        )
      case .software:
        settings.setSoftwareDeviceMuteState(for: try deviceID.readDeviceUID(), to: muted)
      case .ddc:
        throw AdapterError.unsupportedBackend(.ddc)
      }
      muteStates[deviceID] = muted
      lastError = nil
      onMuteChanged?(deviceID, muted)
    } catch { lastError = error }
  }

  @discardableResult
  public func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
    setDefault(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
  }

  @discardableResult
  public func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    setDefault(deviceID, selector: kAudioHardwarePropertyDefaultInputDevice)
  }

  public func start() {
    guard !running else { return }
    running = true
    refreshOutputDeviceStates()
  }

  public func stop() {
    removeListeners()
    running = false
  }

  public func refreshOutputDeviceStates() {
    do {
      let oldOutputUID = defaultDeviceUID
      let oldInputUID = defaultInputDeviceUID
      defaultDeviceID = try AudioProperties.read(
        .system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID.unknown
      )
      let inputID = try AudioProperties.read(
        .system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID.unknown
      )
      defaultDeviceUID = try? defaultDeviceID.readDeviceUID()
      defaultInputDeviceUID = try? inputID.readDeviceUID()
      for device in deviceProvider.outputDevices {
        let tier = outputVolumeBackend(for: device.id)
        let volume: Float
        let muted: Bool
        switch tier {
        case .hardware:
          volume = try AudioProperties.read(
            device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput, initial: Float(0)
          )
          let rawMute = try AudioProperties.read(
            device.id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
            initial: UInt32(0)
          )
          muted = rawMute != 0
        case .software:
          volume = settings.getSoftwareDeviceVolume(for: device.uid) ?? 1
          muted = settings.getSoftwareDeviceMuteState(for: device.uid)
        case .ddc:
          throw AdapterError.unsupportedBackend(.ddc)
        }
        let stored = DeviceVolumePolicy.storedVolume(volume, tier: tier)
        let previousVolume = volumes[device.id]
        let previousMute = muteStates[device.id]
        volumes[device.id] = stored
        muteStates[device.id] = muted
        if previousVolume != stored { onVolumeChanged?(device.id, stored) }
        if previousMute != muted { onMuteChanged?(device.id, muted) }
      }
      if let uid = defaultDeviceUID, uid != oldOutputUID { onDefaultDeviceChanged?(uid) }
      if let uid = defaultInputDeviceUID, uid != oldInputUID { onDefaultInputDeviceChanged?(uid) }
      lastError = nil
      if running { installListeners() }
    } catch { lastError = error }
  }

  public func applyTierOverrideChange(for deviceID: AudioDeviceID) { refreshOutputDeviceStates() }
  public func refreshAfterDDCProbe() { refreshOutputDeviceStates() }

  private func setDefault(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
    do {
      try AudioProperties.write(.system, selector, value: id)
      refreshOutputDeviceStates()
      return true
    } catch {
      lastError = error
      return false
    }
  }

  private func removeListeners() {
    for (object, storedAddress, block) in listeners {
      var address = storedAddress
      AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
    listeners.removeAll()
  }

  private func installListeners() {
    removeListeners()
    let systemProperties = [
      kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
    ]
    .map { (AudioObjectID.system, AudioProperties.address($0)) }
    let deviceProperties = deviceProvider.outputDevices.flatMap { device in
      [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map {
        (device.id, AudioProperties.address($0, scope: kAudioObjectPropertyScopeOutput))
      }
    }
    for (object, storedAddress) in systemProperties + deviceProperties {
      var address = storedAddress
      guard AudioObjectHasProperty(object, &address) else { continue }
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.refreshOutputDeviceStates() }
      }
      if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
        listeners.append((object, address, block))
      }
    }
  }
}
