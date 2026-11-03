import AudioToolbox
import Foundation
import Observation

public struct InputDeviceState: Equatable, Sendable {
  public var volume: Float?
  public var isMuted: Bool?
  public var canSetVolume: Bool
  public var canSetMute: Bool
  public var error: String?
}

/// Input controls are linear HAL scalars, never the output software-gain curve.
@MainActor @Observable
public final class InputDeviceBackend {
  public private(set) var states: [String: InputDeviceState] = [:]
  public private(set) var lastError: (any Error)?
  public private(set) var isRunning = false

  private let devices: any AudioDeviceProviding
  private let reader: any AudioDevicePropertyReading
  private let writer: any AudioDevicePropertyWriting
  private let observer: any AudioDevicePropertyObserving
  private var generation: UInt64 = 0
  private var observations: [PropertyKey: DevicePropertyObservation] = [:]

  private struct PropertyKey: Hashable {
    let device: AudioDeviceID
    let selector: AudioObjectPropertySelector
  }

  public init(
    deviceProvider: any AudioDeviceProviding, reader: any AudioDevicePropertyReading,
    writer: any AudioDevicePropertyWriting, observer: any AudioDevicePropertyObserving
  ) {
    devices = deviceProvider
    self.reader = reader
    self.writer = writer
    self.observer = observer
  }

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    refresh()
  }

  public func stop() {
    isRunning = false
    generation &+= 1
    for observation in observations.values { observation.cancel() }
    observations.removeAll()
  }

  isolated deinit { for observation in observations.values { observation.cancel() } }

  public func refresh() {
    var next: [String: InputDeviceState] = [:]
    var wanted: Set<PropertyKey> = []
    var firstFailure: (any Error)?
    for device in devices.inputDevices {
      var state = InputDeviceState(
        volume: nil, isMuted: nil, canSetVolume: false, canSetMute: false, error: nil)
      do {
        if let selector = volumeSelector(for: device.id) {
          let volume = try reader.readScalar(
            device.id, selector: selector, scope: kAudioObjectPropertyScopeInput, initial: Float(0))
          guard volume.isFinite, (0...1).contains(volume) else {
            throw DeviceBackendError.operationFailed("The input device returned an invalid volume.")
          }
          state.volume = volume
          state.canSetVolume = try canWrite(
            device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
          wanted.insert(PropertyKey(device: device.id, selector: selector))
        }
      } catch {
        state.error = error.localizedDescription
        firstFailure = firstFailure ?? error
      }
      do {
        if reader.hasProperty(
          device.id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        {
          let raw = try reader.readScalar(
            device.id, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput,
            initial: UInt32(0))
          state.isMuted = raw != 0
          state.canSetMute = try canWrite(device.id, selector: kAudioDevicePropertyMute)
          wanted.insert(PropertyKey(device: device.id, selector: kAudioDevicePropertyMute))
        }
      } catch {
        state.error = state.error ?? error.localizedDescription
        firstFailure = firstFailure ?? error
      }
      next[device.uid] = state
    }
    states = next
    lastError = firstFailure
    if isRunning { reconcileObservations(wanted) }
  }

  public func setVolume(forUID uid: String, to volume: Float) throws {
    try attempt(uid: uid) {
      guard volume.isFinite, (0...1).contains(volume) else {
        throw DeviceBackendError.invalidVolume(volume)
      }
      let device = try currentDevice(uid)
      guard try canWrite(device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
      else { throw DeviceBackendError.unsupported("Input volume") }
      try writer.writeScalar(
        device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        scope: kAudioObjectPropertyScopeInput, value: volume)
      refresh()
      if let message = states[uid]?.error { throw DeviceBackendError.operationFailed(message) }
    }
  }

  public func setMute(forUID uid: String, to muted: Bool) throws {
    try attempt(uid: uid) {
      let device = try currentDevice(uid)
      guard try canWrite(device.id, selector: kAudioDevicePropertyMute) else {
        throw DeviceBackendError.unsupported("Input mute")
      }
      try writer.writeScalar(
        device.id, selector: kAudioDevicePropertyMute,
        scope: kAudioObjectPropertyScopeInput, value: UInt32(muted ? 1 : 0))
      refresh()
      if let message = states[uid]?.error { throw DeviceBackendError.operationFailed(message) }
    }
  }

  private func attempt(uid: String, _ work: () throws -> Void) throws {
    do {
      try work()
    } catch {
      lastError = error
      states[uid]?.error = error.localizedDescription
      throw error
    }
  }

  private func currentDevice(_ uid: String) throws -> AudioDevice {
    guard let device = devices.inputDevice(for: uid), device.id.isValid else {
      throw DeviceBackendError.unavailableDevice(uid)
    }
    return device
  }

  private func volumeSelector(for id: AudioDeviceID) -> AudioObjectPropertySelector? {
    for selector in [
      kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar,
    ] where reader.hasProperty(id, selector: selector, scope: kAudioObjectPropertyScopeInput) {
      return selector
    }
    return nil
  }

  private func canWrite(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> Bool {
    guard reader.hasProperty(id, selector: selector, scope: kAudioObjectPropertyScopeInput) else {
      return false
    }
    return try reader.isPropertySettable(
      id, selector: selector, scope: kAudioObjectPropertyScopeInput)
  }

  private func reconcileObservations(_ wanted: Set<PropertyKey>) {
    for key in Set(observations.keys).subtracting(wanted) {
      observations.removeValue(forKey: key)?.cancel()
    }
    let epoch = generation
    for key in wanted where observations[key] == nil {
      do {
        observations[key] = try observer.observe(
          key.device, selector: key.selector, scope: kAudioObjectPropertyScopeInput
        ) { [weak self] in
          guard let self, self.isRunning, self.generation == epoch else { return }
          self.refresh()
        }
      } catch {
        lastError = error
        if let uid = devices.inputDevices.first(where: { $0.id == key.device })?.uid {
          states[uid]?.error = error.localizedDescription
        }
      }
    }
  }
}
