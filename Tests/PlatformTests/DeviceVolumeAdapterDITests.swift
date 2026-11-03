import AudioToolbox
import FineTuneDomain
import Foundation
import Observation
import Testing

@testable import FineTunePlatform

@Suite("Actual output volume adapter DI")
@MainActor
struct DeviceVolumeAdapterDITests {
  @Test("Construction performs zero HAL reads and start owns only injected observations")
  func lifecycle() {
    let rig = OutputAdapterFixture()
    #expect(rig.hal.reads == 0 && rig.observer.active == 0)
    rig.adapter.start()
    #expect(rig.adapter.volumes[10] == 0.25 && rig.observer.active > 0)
    let callback = rig.observer.callbacks.first
    rig.adapter.stop()
    let reads = rig.hal.reads
    callback?()
    #expect(rig.hal.reads == reads && rig.observer.active == 0)
    #expect(rig.provider.starts == 0 && rig.provider.stops == 0)
  }

  @Test(
    "Volume-only hardware remains controllable and publishes quantized readback, never the request")
  func volumeOnlyReadback() throws {
    let rig = OutputAdapterFixture()
    rig.hal.values[OutputHAL.Key(10, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)] =
      nil
    rig.adapter.start()
    #expect(rig.adapter.canSetVolume(for: 10) && !rig.adapter.canSetMute(for: 10))
    #expect(rig.adapter.muteStates[10] == nil)
    rig.hal.volumeReadback = 0.4
    try rig.adapter.requestVolume(forUID: "speaker", to: 0.37)
    #expect(rig.adapter.volumes[10] == 0.4)
    #expect(rig.hal.writes.last?.key.scope == kAudioObjectPropertyScopeOutput)
  }

  @Test("A different failing device cannot make a successful target write fail")
  func perDeviceFailure() throws {
    let rig = OutputAdapterFixture()
    rig.provider.outputDevices.append(OutputProvider.device(11, "bad"))
    rig.hal.values[OutputHAL.Key(11, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)] =
      Float(0.8)
    rig.hal.failedReads.insert(
      OutputHAL.Key(11, kAudioHardwareServiceDeviceProperty_VirtualMainVolume))
    rig.adapter.start()
    #expect(rig.adapter.deviceError(forUID: "bad") != nil)
    try rig.adapter.requestVolume(forUID: "speaker", to: 0.6)
    #expect(rig.adapter.volumes[10] == 0.6 && rig.adapter.deviceError(forUID: "speaker") == nil)
  }

  @Test("A removed UID cannot write a reused HAL ID")
  func removedUID() {
    let rig = OutputAdapterFixture()
    rig.adapter.start()
    rig.provider.outputDevices = [OutputProvider.device(10, "replacement")]
    #expect(throws: (any Error).self) { try rig.adapter.requestVolume(forUID: "speaker", to: 0.6) }
    #expect(rig.hal.writes.isEmpty)
    let rebound = OutputAdapterFixture(resolvedID: 99)
    rebound.adapter.start()
    #expect(throws: (any Error).self) {
      try rebound.adapter.requestVolume(forUID: "speaker", to: 0.6)
    }
    #expect(rebound.hal.writes.isEmpty)
  }

  @Test(
    "DDC consumes observed state, except the confirmed muted logical restore, without stealing callbacks"
  )
  func ddcProjection() {
    let rig = OutputAdapterFixture(ddc: true)
    var callbackCount = 0
    rig.ddc.onChange = { callbackCount += 1 }
    rig.ddc.states["speaker"] = DDCVolumeState(
      observedPercent: 50, requestedPercent: 80, isMuted: false, isApplying: true, error: nil)
    rig.adapter.start()
    #expect(rig.adapter.volumes[10] == 0.5 && rig.adapter.outputProcessingGain(for: 10) == 1)
    rig.ddc.states["speaker"] = DDCVolumeState(
      observedPercent: 0, requestedPercent: 75, isMuted: true, isApplying: false, error: nil)
    rig.adapter.refreshAfterDDCProbe()
    #expect(rig.adapter.volumes[10] == 0.75 && rig.adapter.muteStates[10] == true)
    rig.ddc.states["speaker"] = DDCVolumeState(
      observedPercent: nil, requestedPercent: 80, isMuted: false, isApplying: false,
      error: "Unavailable")
    rig.adapter.refreshAfterDDCProbe()
    #expect(rig.adapter.volumes[10] == nil && !rig.adapter.canSetVolume(for: 10))
    rig.ddc.onChange?()
    #expect(callbackCount == 1)
  }

  @Test("Software tiny gain is preserved and hardware never applies that gain twice")
  func softwareAndHardwareGain() throws {
    let rig = OutputAdapterFixture()
    rig.settings.setDeviceVolumeTierOverride(for: "speaker", to: .software)
    rig.adapter.start()
    try rig.adapter.requestVolume(forUID: "speaker", to: 0.0039)
    #expect(rig.adapter.volumes[10] == 0.0039)
    #expect(rig.adapter.outputProcessingGain(for: 10) == 0.0039)
    #expect(rig.hal.writes.isEmpty)
    rig.settings.setDeviceVolumeTierOverride(for: "speaker", to: .hardware)
    rig.adapter.applyTierOverrideChange(for: 10)
    #expect(rig.adapter.outputProcessingGain(for: 10) == 1)
  }

  @Test("Same-UID default read health is observable per role and recovery retains display identity")
  func defaultReadHealth() async {
    let rig = OutputAdapterFixture()
    rig.adapter.start()
    let inputKey = OutputHAL.Key(.system, kAudioHardwarePropertyDefaultInputDevice)
    let outputKey = OutputHAL.Key(.system, kAudioHardwarePropertyDefaultOutputDevice)
    func refresh(_ change: () -> Void) async {
      await withCheckedContinuation { continuation in
        withObservationTracking {
          _ = rig.adapter.defaultOutputReadFailure
          _ = rig.adapter.defaultInputReadFailure
        } onChange: {
          continuation.resume()
        }
        change()
        rig.adapter.refreshOutputDeviceStates()
      }
    }
    #expect(
      rig.adapter.defaultOutputReadFailure == nil && rig.adapter.defaultInputReadFailure == nil)
    await refresh { rig.hal.failedReads.insert(inputKey) }
    #expect(
      rig.adapter.defaultOutputReadFailure == nil && rig.adapter.defaultInputReadFailure != nil)
    #expect(
      rig.adapter.defaultDeviceUID == "speaker" && rig.adapter.defaultInputDeviceUID == "microphone"
    )
    await refresh { rig.hal.failedReads = [outputKey] }
    #expect(
      rig.adapter.defaultOutputReadFailure != nil && rig.adapter.defaultInputReadFailure == nil)
    #expect(!rig.adapter.hasCurrentDefaultOutput)
    await refresh { rig.hal.failedReads.removeAll() }
    #expect(
      rig.adapter.defaultOutputReadFailure == nil && rig.adapter.defaultInputReadFailure == nil)
    #expect(
      rig.adapter.hasCurrentDefaultOutput && rig.adapter.defaultInputDeviceUID == "microphone")
    #expect(rig.hal.writes.isEmpty)
  }

  @Test("Default writes use global scope and success requires actual target readback")
  func defaultReadback() {
    let rig = OutputAdapterFixture()
    rig.provider.outputDevices.append(OutputProvider.device(11, "other"))
    rig.adapter.start()
    rig.hal.ignoreWrites = true
    #expect(!rig.adapter.setDefaultDevice(11))
    #expect(rig.adapter.defaultDeviceUID == "speaker")
    #expect(
      rig.hal.writes.last?.key == OutputHAL.Key(.system, kAudioHardwarePropertyDefaultOutputDevice))
  }
}

@MainActor
private final class OutputAdapterFixture {
  let provider = OutputProvider()
  let hal = OutputHAL()
  let observer = OutputObserver()
  let ddc = OutputDDC()
  let settings: SettingsManager
  let adapter: CoreAudioDeviceVolumeAdapter

  init(ddc enabled: Bool = false, resolvedID: AudioDeviceID? = nil) {
    settings = SettingsManager(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "output-DI-\(UUID())"),
      launchAtLoginService: OutputLogin())
    adapter = CoreAudioDeviceVolumeAdapter(
      deviceProvider: provider, settingsManager: settings,
      autoDetectedBackend: { _ in enabled ? .ddc : .hardware }, reader: hal, writer: hal,
      observer: observer, ddcController: enabled ? ddc : nil,
      resolveUID: { [provider] uid in
        guard let device = provider.device(for: uid) ?? provider.inputDevice(for: uid) else {
          throw DeviceBackendError.unavailableDevice(uid)
        }
        return resolvedID ?? device.id
      })
  }
}

@MainActor
private final class OutputProvider: AudioDeviceProviding {
  var outputDevices = [device(10, "speaker")]
  var inputDevices = [device(20, "microphone")]
  var starts = 0
  var stops = 0
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  func start() { starts += 1 }
  func stop() { stops += 1 }
  static func device(_ id: AudioDeviceID, _ uid: String) -> AudioDevice {
    AudioDevice(id: id, uid: uid, name: uid, icon: nil, supportsAutoEQ: false)
  }
}

nonisolated private final class OutputHAL: AudioDevicePropertyReading, AudioDevicePropertyWriting {
  struct Key: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    init(
      _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
      _ scope: AudioObjectPropertyScope? = nil
    ) {
      self.object = object
      self.selector = selector
      self.scope =
        scope
        ?? (object == .system ? kAudioObjectPropertyScopeGlobal : kAudioObjectPropertyScopeOutput)
    }
  }
  struct Write {
    let key: Key
    let value: Any
  }
  var values: [Key: Any] = [
    Key(.system, kAudioHardwarePropertyDefaultOutputDevice): AudioDeviceID(10),
    Key(.system, kAudioHardwarePropertyDefaultInputDevice): AudioDeviceID(20),
    Key(10, kAudioHardwareServiceDeviceProperty_VirtualMainVolume): Float(0.25),
    Key(10, kAudioDevicePropertyMute): UInt32(0),
  ]
  var failedReads: Set<Key> = []
  var volumeReadback: Float?
  var ignoreWrites = false
  var reads = 0
  var writes: [Write] = []
  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> Value {
    reads += 1
    let key = Key(object, selector, scope)
    guard !failedReads.contains(key), let value = values[key] as? Value else {
      throw OutputFailure.read
    }
    return value
  }
  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> [Value] { throw OutputFailure.read }
  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool { values[Key(object, selector, scope)] != nil }
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool { hasProperty(object, selector: selector, scope: scope) }
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    value: Value
  ) throws {
    let key = Key(object, selector, scope)
    writes.append(Write(key: key, value: value))
    if !ignoreWrites {
      values[key] =
        selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        ? volumeReadback ?? (value as? Float) : value
    }
  }
}

@MainActor
private final class OutputObserver: AudioDevicePropertyObserving {
  var callbacks: [@MainActor @Sendable () -> Void] = []
  var active = 0
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    active += 1
    callbacks.append(onChange)
    return DevicePropertyObservation { [weak self] in self?.active -= 1 }
  }
}

@MainActor
private final class OutputDDC: DDCVolumeControlling {
  var states: [String: DDCVolumeState] = [:]
  var lastError: (any Error)?
  var onChange: (() -> Void)?
  func requestVolume(forUID uid: String, to volume: Float) throws {}
  func requestMute(forUID uid: String, to muted: Bool) throws {}
}

@MainActor
private final class OutputLogin: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
private enum OutputFailure: Error { case read }
