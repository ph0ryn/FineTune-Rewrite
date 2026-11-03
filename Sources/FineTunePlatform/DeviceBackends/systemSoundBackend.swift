import AudioToolbox
import Foundation
import Observation

/// The system-sound destination is distinct from the normal default audio output.
@MainActor @Observable
public final class SystemSoundBackend {
  public private(set) var outputUID: String?
  public private(set) var canSetOutput = false
  public private(set) var lastError: (any Error)?
  public var onOutputChanged: ((String?) -> Void)?

  private let devices: any AudioDeviceProviding
  private let reader: any AudioDevicePropertyReading
  private let writer: any AudioDevicePropertyWriting
  private let observer: any AudioDevicePropertyObserving
  private var observation: DevicePropertyObservation?
  private var generation: UInt64 = 0
  private var running = false

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
    guard !running else { return }
    running = true
    generation &+= 1
    refresh()
    guard hasProperty else { return }
    let epoch = generation
    do {
      observation = try observer.observe(
        .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        scope: kAudioObjectPropertyScopeGlobal
      ) { [weak self] in
        guard let self, self.running, self.generation == epoch else { return }
        self.refresh()
      }
    } catch {
      lastError = error
    }
  }

  public func stop() {
    running = false
    generation &+= 1
    observation?.cancel()
    observation = nil
  }

  isolated deinit { observation?.cancel() }

  public func refresh() {
    do {
      guard hasProperty else { throw DeviceBackendError.unsupported("System sound output") }
      let id = try reader.readScalar(
        AudioObjectID.system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        scope: kAudioObjectPropertyScopeGlobal, initial: AudioDeviceID.unknown)
      let observed = devices.outputDevices.first { $0.id == id }?.uid
      canSetOutput = try reader.isPropertySettable(
        .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        scope: kAudioObjectPropertyScopeGlobal)
      let previous = outputUID
      outputUID = observed
      lastError = nil
      if previous != observed { onOutputChanged?(observed) }
    } catch {
      canSetOutput = false
      lastError = error
    }
  }

  public func setOutput(forUID uid: String) throws {
    do {
      guard let device = devices.device(for: uid), device.id.isValid else {
        throw DeviceBackendError.unavailableDevice(uid)
      }
      guard hasProperty,
        try reader.isPropertySettable(
          .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
          scope: kAudioObjectPropertyScopeGlobal)
      else { throw DeviceBackendError.unsupported("System sound output") }
      try writer.writeScalar(
        .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        scope: kAudioObjectPropertyScopeGlobal, value: device.id)
      refresh()
      if let lastError { throw lastError }
    } catch {
      lastError = error
      throw error
    }
  }

  private var hasProperty: Bool {
    reader.hasProperty(
      .system, selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
      scope: kAudioObjectPropertyScopeGlobal)
  }
}
