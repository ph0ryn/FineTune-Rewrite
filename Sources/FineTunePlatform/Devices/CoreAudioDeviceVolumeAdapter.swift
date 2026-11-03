import AudioToolbox
import FineTuneDomain
import Observation

/// One output owner: hardware readback, DDC observations and software preferences never share a curve.
@Observable @MainActor
public final class CoreAudioDeviceVolumeAdapter: DeviceVolumeProviding {
  public enum AdapterError: Error {
    case unsupportedBackend(VolumeControlTier)
    case invalidVolume(Float)
  }

  public private(set) var defaultDeviceID: AudioDeviceID = .unknown
  public private(set) var defaultDeviceUID: String?
  public private(set) var defaultInputDeviceUID: String?
  /// A failed read may retain last-good identity for display, never for follow-default effects.
  public var hasCurrentDefaultOutput: Bool {
    defaultDeviceUID != nil && defaultErrors[kAudioHardwarePropertyDefaultOutputDevice] == nil
  }
  /// Discovery and each role's default read have independent health; these are cached, observable reads.
  public var defaultOutputReadFailure: String? {
    defaultErrors[kAudioHardwarePropertyDefaultOutputDevice]?.localizedDescription
  }
  public var defaultInputReadFailure: String? {
    defaultErrors[kAudioHardwarePropertyDefaultInputDevice]?.localizedDescription
  }
  public private(set) var volumes: [AudioDeviceID: Float] = [:]
  public private(set) var muteStates: [AudioDeviceID: Bool] = [:]
  public private(set) var lastError: (any Error)?
  public var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
  public var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
  public var onDefaultDeviceChanged: ((String) -> Void)?
  public var onDefaultInputDeviceChanged: ((String) -> Void)?
  private var automaticTiers: [AudioDeviceID: VolumeControlTier] = [:]
  private var writableVolumes: Set<AudioDeviceID> = []
  private var writableMutes: Set<AudioDeviceID> = []
  private var deviceErrors: [String: any Error] = [:]
  private var defaultErrors: [AudioObjectPropertySelector: any Error] = [:]
  private let deviceProvider: any AudioDeviceProviding
  private let settings: SettingsManager
  private let detectBackend: (@MainActor (AudioDeviceID) -> VolumeControlTier)?
  private let reader: any AudioDevicePropertyReading
  private let writer: any AudioDevicePropertyWriting
  private let observer: any AudioDevicePropertyObserving
  private let ddc: (any DDCVolumeControlling)?
  private let resolveUID: @MainActor (String) throws -> AudioDeviceID
  @ObservationIgnored private var running = false
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var observations: [PropertyKey: DevicePropertyObservation] = [:]

  private struct PropertyKey: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
  }

  public init(
    deviceProvider: any AudioDeviceProviding, settingsManager: SettingsManager,
    autoDetectedBackend: (@MainActor (AudioDeviceID) -> VolumeControlTier)? = nil,
    reader: any AudioDevicePropertyReading = CoreAudioDevicePropertyReader(),
    writer: any AudioDevicePropertyWriting = CoreAudioDevicePropertyWriter(),
    observer: any AudioDevicePropertyObserving = CoreAudioDevicePropertyObserver(),
    ddcController: (any DDCVolumeControlling)? = nil,
    resolveUID: @escaping @MainActor (String) throws -> AudioDeviceID = {
      try CoreAudioDeviceUIDResolver.resolve(uid: $0)
    }
  ) {
    self.deviceProvider = deviceProvider
    settings = settingsManager
    detectBackend = autoDetectedBackend
    self.reader = reader
    self.writer = writer
    self.observer = observer
    ddc = ddcController
    self.resolveUID = resolveUID
  }

  public func canSetVolume(for deviceID: AudioDeviceID) -> Bool {
    writableVolumes.contains(deviceID)
  }
  public func canSetMute(for deviceID: AudioDeviceID) -> Bool { writableMutes.contains(deviceID) }
  public func deviceError(forUID uid: String) -> String? { deviceErrors[uid]?.localizedDescription }

  /// Projection-only: no live probe. Absence is unknown support, not an inferred hardware tier.
  /// An explicitly supplied detection policy is expected to be pure/precomputed.
  public func cachedAutomaticOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier?
  {
    automaticTiers[deviceID] ?? detectBackend?(deviceID)
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
    automaticTiers[deviceID] ?? detectAutomaticBackend(for: deviceID)
  }

  private func detectAutomaticBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
    if let detectBackend { return detectBackend(deviceID) }
    if let device = deviceProvider.outputDevices.first(where: { $0.id == deviceID }),
      ddc?.states[device.uid] != nil
    {
      return .ddc
    }
    guard
      reader.hasProperty(
        deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        scope: kAudioObjectPropertyScopeOutput)
    else { return .software }
    do {
      return try canWrite(deviceID, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        ? .hardware : .software
    } catch {
      // The property exists; unknown writability must not invent successful software capability.
      return .hardware
    }
  }

  public func outputProcessingGain(for deviceID: AudioDeviceID) -> Float {
    outputVolumeBackend(for: deviceID) == .software ? volumes[deviceID] ?? 1 : 1
  }

  /// UID commands are the actual product entry. Legacy HAL-ID methods below retain source compatibility.
  public func requestVolume(forUID uid: String, to volume: Float) throws {
    do {
      guard volume.isFinite, (0...1).contains(volume) else {
        throw AdapterError.invalidVolume(volume)
      }
      let device = try currentOutput(uid)
      let tier = outputVolumeBackend(for: device.id)
      switch tier {
      case .hardware:
        try validateBinding(device)
        guard
          try canWrite(device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        else { throw DeviceBackendError.unsupported("Output volume") }
        try writer.writeScalar(
          device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
          scope: kAudioObjectPropertyScopeOutput,
          value: DeviceVolumePolicy.storedVolume(volume, tier: .hardware))
      case .software:
        settings.setSoftwareDeviceVolume(for: uid, to: volume)
        settings.setSoftwareDeviceSavedVolume(for: uid, to: volume)
      case .ddc:
        guard let ddc else { throw AdapterError.unsupportedBackend(.ddc) }
        try ddc.requestVolume(forUID: uid, to: volume)
      }
      refreshOutputDeviceStates()
      if let error = deviceErrors[uid] { throw error }
      if tier == .hardware, volumes[device.id] == nil {
        throw DeviceBackendError.unsupported("Output volume readback")
      }
    } catch {
      record(error, uid: uid)
      throw error
    }
  }

  public func requestMute(forUID uid: String, to muted: Bool) throws {
    do {
      let device = try currentOutput(uid)
      let tier = outputVolumeBackend(for: device.id)
      switch tier {
      case .hardware:
        try validateBinding(device)
        guard try canWrite(device.id, selector: kAudioDevicePropertyMute) else {
          throw DeviceBackendError.unsupported("Output mute")
        }
        try writer.writeScalar(
          device.id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
          value: UInt32(muted ? 1 : 0))
      case .software:
        settings.setSoftwareDeviceMuteState(for: uid, to: muted)
      case .ddc:
        guard let ddc else { throw AdapterError.unsupportedBackend(.ddc) }
        try ddc.requestMute(forUID: uid, to: muted)
      }
      refreshOutputDeviceStates()
      if let error = deviceErrors[uid] { throw error }
      if tier == .hardware, muteStates[device.id] != muted {
        throw DeviceBackendError.operationFailed(
          "The output device did not confirm the requested mute state.")
      }
    } catch {
      record(error, uid: uid)
      throw error
    }
  }

  public func setVolume(for deviceID: AudioDeviceID, to volume: Float) {
    do { try requestVolume(forUID: uid(for: deviceID), to: volume) } catch { lastError = error }
  }
  public func setMute(for deviceID: AudioDeviceID, to muted: Bool) {
    do { try requestMute(forUID: uid(for: deviceID), to: muted) } catch { lastError = error }
  }

  @discardableResult public func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
    setDefault(deviceID, input: false)
  }
  @discardableResult public func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
    setDefault(deviceID, input: true)
  }

  public func start() {
    guard !running else { return }
    running = true
    generation &+= 1
    refreshOutputDeviceStates()
  }
  public func stop() {
    running = false
    generation &+= 1
    for observation in observations.values { observation.cancel() }
    observations.removeAll()
  }
  isolated deinit { for observation in observations.values { observation.cancel() } }

  public func refreshOutputDeviceStates() {
    let oldVolumes = volumes
    let oldMutes = muteStates
    let oldOutput = defaultDeviceUID
    let oldInput = defaultInputDeviceUID
    readDefaults()
    var detected: [AudioDeviceID: VolumeControlTier] = [:]
    for device in deviceProvider.outputDevices {
      detected[device.id] = detectAutomaticBackend(for: device.id)
    }
    automaticTiers = detected
    var nextVolumes: [AudioDeviceID: Float] = [:]
    var nextMutes: [AudioDeviceID: Bool] = [:]
    var nextVolumeWrites: Set<AudioDeviceID> = []
    var nextMuteWrites: Set<AudioDeviceID> = []
    var errors: [String: any Error] = [:]
    for device in deviceProvider.outputDevices {
      switch outputVolumeBackend(for: device.id) {
      case .hardware:
        do {
          let selector =
            reader.hasProperty(
              device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
              scope: kAudioObjectPropertyScopeOutput)
            ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume
            : kAudioDevicePropertyVolumeScalar
          if reader.hasProperty(
            device.id, selector: selector, scope: kAudioObjectPropertyScopeOutput)
          {
            let value = try reader.readScalar(
              device.id, selector: selector, scope: kAudioObjectPropertyScopeOutput,
              initial: Float(0))
            guard value.isFinite, (0...1).contains(value) else {
              throw DeviceBackendError.operationFailed("The output returned an invalid volume.")
            }
            nextVolumes[device.id] = value
            if try canWrite(
              device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            {
              nextVolumeWrites.insert(device.id)
            }
          }
        } catch { errors[device.uid] = error }
        do {
          if reader.hasProperty(
            device.id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
          {
            let value = try reader.readScalar(
              device.id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
              initial: UInt32(0))
            nextMutes[device.id] = value != 0
            if try canWrite(device.id, selector: kAudioDevicePropertyMute) {
              nextMuteWrites.insert(device.id)
            }
          }
        } catch { errors[device.uid] = errors[device.uid] ?? error }
      case .software:
        nextVolumes[device.id] = settings.getSoftwareDeviceVolume(for: device.uid) ?? 1
        nextMutes[device.id] = settings.getSoftwareDeviceMuteState(for: device.uid)
        nextVolumeWrites.insert(device.id)
        nextMuteWrites.insert(device.id)
      case .ddc:
        if let state = ddc?.states[device.uid], let observed = state.observedPercent {
          let percent =
            state.isMuted && observed == 0 ? state.requestedPercent ?? observed : observed
          nextVolumes[device.id] = Float(percent) / 100
          nextMutes[device.id] = state.isMuted
          nextVolumeWrites.insert(device.id)
          nextMuteWrites.insert(device.id)
          if let message = state.error {
            errors[device.uid] = DeviceBackendError.operationFailed(message)
          }
        } else {
          errors[device.uid] = DeviceBackendError.operationFailed(
            ddc?.states[device.uid]?.error
              ?? "DDC volume is not currently available for this output.")
        }
      }
    }
    volumes = nextVolumes
    muteStates = nextMutes
    writableVolumes = nextVolumeWrites
    writableMutes = nextMuteWrites
    deviceErrors = errors
    lastError =
      defaultErrors.values.first ?? deviceProvider.outputDevices.compactMap { errors[$0.uid] }.first
    if running { reconcileObservations() }
    for (id, value) in nextVolumes where oldVolumes[id] != value { onVolumeChanged?(id, value) }
    for (id, value) in nextMutes where oldMutes[id] != value { onMuteChanged?(id, value) }
    if let uid = defaultDeviceUID, oldOutput != uid { onDefaultDeviceChanged?(uid) }
    if let uid = defaultInputDeviceUID, oldInput != uid { onDefaultInputDeviceChanged?(uid) }
  }

  public func applyTierOverrideChange(for deviceID: AudioDeviceID) { refreshOutputDeviceStates() }
  public func refreshAfterDDCProbe() { refreshOutputDeviceStates() }

  private func currentOutput(_ uid: String) throws -> AudioDevice {
    guard let device = deviceProvider.outputDevices.first(where: { $0.uid == uid }),
      device.id.isValid
    else {
      throw DeviceBackendError.unavailableDevice(uid)
    }
    return device
  }
  private func uid(for id: AudioDeviceID) throws -> String {
    guard let uid = deviceProvider.outputDevices.first(where: { $0.id == id })?.uid else {
      throw DeviceBackendError.unavailableDevice("HAL output \(id)")
    }
    return uid
  }
  private func validateBinding(_ device: AudioDevice) throws {
    guard try resolveUID(device.uid) == device.id else {
      throw DeviceBackendError.unavailableDevice(device.uid)
    }
  }
  private func canWrite(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> Bool {
    guard reader.hasProperty(id, selector: selector, scope: kAudioObjectPropertyScopeOutput) else {
      return false
    }
    return try reader.isPropertySettable(
      id, selector: selector, scope: kAudioObjectPropertyScopeOutput)
  }
  private func record(_ error: any Error, uid: String) {
    deviceErrors[uid] = error
    lastError = error
  }

  private func readDefaults() {
    defaultErrors.removeAll()
    for input in [false, true] {
      let selector =
        input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
      do {
        let id = try reader.readScalar(
          AudioObjectID.system, selector: selector, scope: kAudioObjectPropertyScopeGlobal,
          initial: AudioDeviceID.unknown)
        let devices = input ? deviceProvider.inputDevices : deviceProvider.outputDevices
        let uid = devices.first { $0.id == id }?.uid
        guard !id.isValid || uid != nil else {
          throw DeviceBackendError.unavailableDevice("Current default audio device")
        }
        if input {
          defaultInputDeviceUID = uid
        } else {
          defaultDeviceID = id
          defaultDeviceUID = uid
        }
      } catch { defaultErrors[selector] = error }
    }
  }

  private func setDefault(_ id: AudioDeviceID, input: Bool) -> Bool {
    let selector =
      input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    do {
      let devices = input ? deviceProvider.inputDevices : deviceProvider.outputDevices
      guard let device = devices.first(where: { $0.id == id }), id.isValid else {
        throw DeviceBackendError.unavailableDevice("HAL device \(id)")
      }
      try validateBinding(device)
      guard
        try reader.isPropertySettable(
          .system, selector: selector, scope: kAudioObjectPropertyScopeGlobal)
      else { throw DeviceBackendError.unsupported("Default audio device selection") }
      try writer.writeScalar(
        .system, selector: selector, scope: kAudioObjectPropertyScopeGlobal, value: id)
      refreshOutputDeviceStates()
      if let error = defaultErrors[selector] { throw error }
      let observed = input ? defaultInputDeviceUID : defaultDeviceUID
      guard observed == device.uid else {
        throw DeviceBackendError.operationFailed(
          "The system did not confirm the requested default audio device.")
      }
      return true
    } catch {
      lastError = error
      return false
    }
  }

  private func reconcileObservations() {
    var wanted: Set<PropertyKey> = []
    for selector in [
      kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
    ] {
      if reader.hasProperty(.system, selector: selector, scope: kAudioObjectPropertyScopeGlobal) {
        wanted.insert(
          PropertyKey(object: .system, selector: selector, scope: kAudioObjectPropertyScopeGlobal))
      }
    }
    for device in deviceProvider.outputDevices {
      for selector in [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyMute,
      ] {
        if reader.hasProperty(device.id, selector: selector, scope: kAudioObjectPropertyScopeOutput)
        {
          wanted.insert(
            PropertyKey(
              object: device.id, selector: selector, scope: kAudioObjectPropertyScopeOutput))
        }
      }
    }
    for (key, observation) in observations where !wanted.contains(key) {
      observation.cancel()
      observations[key] = nil
    }
    let epoch = generation
    for key in wanted where observations[key] == nil {
      do {
        observations[key] = try observer.observe(
          key.object, selector: key.selector, scope: key.scope
        ) { [weak self] in
          guard let self, self.running, self.generation == epoch else { return }
          self.refreshOutputDeviceStates()
        }
      } catch { lastError = error }
    }
  }
}
