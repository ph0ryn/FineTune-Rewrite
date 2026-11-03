import AudioToolbox
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@Suite("Device backend boundary")
@MainActor
struct DeviceBackendTests {
  @Test("Input controls use input-scope scalar units and publish quantized readback")
  func inputScalarAndReadback() throws {
    let provider = BackendDeviceProvider()
    provider.inputDevices = [backendDevice("microphone", id: 101)]
    let hal = BackendHAL()
    hal.set(101, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float(0.4))
    hal.set(101, kAudioDevicePropertyMute, .input, UInt32(0))
    hal.quantize = true
    let backend = InputDeviceBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    #expect(hal.reads == 0 && hal.writes.isEmpty)
    backend.start()
    #expect(backend.states["microphone"]?.volume == 0.4)
    try backend.setVolume(forUID: "microphone", to: 0.63)
    #expect(backend.states["microphone"]?.volume == 0.625)
    #expect(hal.writes.last?.scope == kAudioObjectPropertyScopeInput)
    try backend.setMute(forUID: "microphone", to: true)
    #expect(backend.states["microphone"]?.isMuted == true)
    backend.stop()
  }

  @Test("Partial input capability is explicit; unsupported mute never writes")
  func partialInputCapability() throws {
    let provider = BackendDeviceProvider()
    provider.inputDevices = [backendDevice("volume-only", id: 102)]
    let hal = BackendHAL()
    hal.set(102, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float(0.6))
    let backend = InputDeviceBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    backend.refresh()
    let state = try #require(backend.states["volume-only"])
    #expect(state.canSetVolume && !state.canSetMute)
    #expect(state.volume == 0.6 && state.isMuted == nil)
    #expect(throws: (any Error).self) {
      try backend.setMute(forUID: "volume-only", to: true)
    }
    #expect(hal.writes.isEmpty)
  }

  @Test("Invalid, missing, and failed input requests do not fabricate an observed value")
  func inputFailures() throws {
    let provider = BackendDeviceProvider()
    provider.inputDevices = [backendDevice("mic", id: 103)]
    let hal = BackendHAL()
    hal.set(103, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float(0.2))
    let backend = InputDeviceBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    backend.refresh()
    #expect(throws: (any Error).self) { try backend.setVolume(forUID: "mic", to: .nan) }
    #expect(throws: (any Error).self) { try backend.setVolume(forUID: "missing", to: 0.8) }
    #expect(hal.writes.isEmpty)
    hal.writeFailure = DeviceBackendError.osStatus(-50)
    #expect(throws: (any Error).self) { try backend.setVolume(forUID: "mic", to: 0.8) }
    #expect(backend.states["mic"]?.volume == 0.2)
    #expect(backend.lastError != nil)
  }

  @Test("A different input's failed read does not turn a successful targeted write into failure")
  func independentInputFailures() throws {
    let provider = BackendDeviceProvider()
    provider.inputDevices = [backendDevice("good", id: 105), backendDevice("bad", id: 106)]
    let hal = BackendHAL()
    hal.set(105, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float(0.2))
    hal.set(106, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float.infinity)
    let backend = InputDeviceBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    backend.refresh()
    try backend.setVolume(forUID: "good", to: 0.6)
    #expect(backend.states["good"]?.volume == 0.6)
    #expect(backend.states["good"]?.error == nil)
    #expect(backend.states["bad"]?.error != nil)
  }

  @Test("System sounds select the system-output property without changing regular default")
  func systemSoundsAreIndependent() throws {
    let provider = BackendDeviceProvider()
    provider.outputDevices = [backendDevice("main", id: 201), backendDevice("alerts", id: 202)]
    let hal = BackendHAL()
    hal.set(.system, kAudioHardwarePropertyDefaultOutputDevice, .global, AudioDeviceID(201))
    hal.set(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, .global, AudioDeviceID(201))
    let backend = SystemSoundBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    #expect(hal.reads == 0)
    backend.start()
    try backend.setOutput(forUID: "alerts")
    #expect(backend.outputUID == "alerts")
    #expect(hal.writes.last?.selector == kAudioHardwarePropertyDefaultSystemOutputDevice)
    let regular: AudioDeviceID = try hal.readScalar(
      .system, selector: kAudioHardwarePropertyDefaultOutputDevice,
      scope: kAudioObjectPropertyScopeGlobal, initial: AudioDeviceID.unknown)
    #expect(regular == 201)
    backend.stop()
  }

  @Test("Unsupported or failed system-output writes remain observable and do not fake a selection")
  func systemSoundFailure() throws {
    let provider = BackendDeviceProvider()
    provider.outputDevices = [backendDevice("main", id: 203), backendDevice("other", id: 204)]
    let hal = BackendHAL()
    hal.set(
      .system, kAudioHardwarePropertyDefaultSystemOutputDevice, .global, AudioDeviceID(203),
      settable: false)
    let backend = SystemSoundBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    backend.refresh()
    #expect(!backend.canSetOutput)
    #expect(throws: (any Error).self) { try backend.setOutput(forUID: "other") }
    #expect(backend.outputUID == "main" && hal.writes.isEmpty)
    hal.set(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, .global, AudioDeviceID(203))
    hal.writeFailure = DeviceBackendError.osStatus(-50)
    #expect(throws: (any Error).self) { try backend.setOutput(forUID: "other") }
    #expect(backend.outputUID == "main" && backend.lastError != nil)
  }

  @Test("Alert writes debounce to the latest rounded percent and confirm the observed readback")
  func alertDebounceAndReadback() async throws {
    let clock = BackendManualClock()
    let scripts = BackendScriptSpy(percent: 20)
    let backend = AlertVolumeBackend(
      scriptRunner: scripts, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    #expect(await scripts.calls.isEmpty)
    await backend.refresh()
    #expect(backend.observedVolume == 0.2)
    let first = Task { try await backend.setVolume(0.376) }
    await clock.waitForSleepCount(1)
    let second = Task { try await backend.setVolume(0.444) }
    await clock.waitForSleepCount(2)
    await clock.advance(by: .milliseconds(100))
    try await second.value
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(backend.observedVolume == 0.44 && !backend.isApplying)
    #expect(
      await scripts.calls == [
        "get alert volume of (get volume settings)", "set volume alert volume 44",
        "get alert volume of (get volume settings)",
      ])
    try await backend.setVolume(0.44)
    #expect(await scripts.calls.count == 3)
  }

  @Test("Alert command success without matching readback is not reported as applied")
  func alertUnconfirmedWrite() async {
    let clock = BackendManualClock()
    let scripts = BackendScriptSpy(percent: 20, ignoreWrites: true)
    let backend = AlertVolumeBackend(
      scriptRunner: scripts, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    await backend.refresh()
    let request = Task { try await backend.setVolume(0.7) }
    await clock.waitForSleepCount(1)
    await clock.advance(by: .milliseconds(100))
    await #expect(throws: (any Error).self) { try await request.value }
    #expect(backend.observedVolume == 0.2)
    #expect(backend.requestedVolume == 0.7 && backend.lastError != nil)
    #expect(!backend.isApplying)
  }

  @Test("Stopping an alert request cancels its pending write without executing a script")
  func alertStopAndValidation() async {
    let clock = BackendManualClock()
    let scripts = BackendScriptSpy(percent: 20)
    let backend = AlertVolumeBackend(
      scriptRunner: scripts, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    await #expect(throws: (any Error).self) { try await backend.setVolume(.nan) }
    let request = Task { try await backend.setVolume(0.7) }
    await clock.waitForSleepCount(1)
    backend.stop()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(await scripts.calls.isEmpty)
    #expect(backend.observedVolume == nil && !backend.isApplying)
  }

  @Test("Input listener cancellation is idempotent and old callbacks cannot publish")
  func inputLifecycle() {
    let provider = BackendDeviceProvider()
    provider.inputDevices = [backendDevice("mic", id: 104)]
    let hal = BackendHAL()
    hal.set(104, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, .input, Float(0.2))
    let backend = InputDeviceBackend(
      deviceProvider: provider, reader: hal, writer: hal, observer: hal)
    backend.start()
    backend.start()
    #expect(hal.activeObservations == 1)
    let oldCallback = hal.callbacks.first
    backend.stop()
    backend.stop()
    #expect(hal.activeObservations == 0)
    let readCount = hal.reads
    oldCallback?()
    #expect(hal.reads == readCount)
    provider.inputDevices = []
    backend.start()
    #expect(backend.states.isEmpty)
    backend.stop()
  }
}

private func backendDevice(_ uid: String, id: AudioDeviceID) -> AudioDevice {
  AudioDevice(id: id, uid: uid, name: uid, icon: nil, supportsAutoEQ: false)
}

@MainActor
private final class BackendDeviceProvider: AudioDeviceProviding {
  var outputDevices: [AudioDevice] = []
  var inputDevices: [AudioDevice] = []
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  func start() {}
  func stop() {}
}

nonisolated private final class BackendHAL: AudioDevicePropertyReading, AudioDevicePropertyWriting,
  AudioDevicePropertyObserving
{
  struct Key: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
  }
  var values: [Key: Any] = [:]
  var writable: Set<Key> = []
  var reads = 0
  var writes: [Key] = []
  var writeFailure: (any Error)?
  var quantize = false
  @MainActor var callbacks: [@MainActor @Sendable () -> Void] = []
  @MainActor var activeObservations = 0

  func set<Value>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    _ scope: AudioScope, _ value: Value, settable: Bool = true
  ) {
    let key = Key(object: object, selector: selector, scope: scope.propertyScope)
    values[key] = value
    if settable { writable.insert(key) }
  }

  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value {
    reads += 1
    guard let value = values[Key(object: object, selector: selector, scope: scope)] as? Value else {
      throw DeviceBackendError.operationFailed("Unexpected HAL read in a unit test.")
    }
    return value
  }

  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value] {
    throw DeviceBackendError.operationFailed("Unexpected HAL array read in a unit test.")
  }

  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool { values[Key(object: object, selector: selector, scope: scope)] != nil }

  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool { writable.contains(Key(object: object, selector: selector, scope: scope)) }

  @MainActor
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, value: Value
  ) throws {
    if let writeFailure { throw writeFailure }
    let key = Key(object: object, selector: selector, scope: scope)
    writes.append(key)
    if quantize, let scalar = value as? Float {
      values[key] = (scalar * 16).rounded() / 16
    } else {
      values[key] = value
    }
  }

  @MainActor
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    activeObservations += 1
    callbacks.append(onChange)
    return DevicePropertyObservation { [weak self] in self?.activeObservations -= 1 }
  }
}

private actor BackendScriptSpy: DeviceScriptRunning {
  private var percent: Int
  private let ignoreWrites: Bool
  private let writeStatus: Int32
  private let readOverride: String?
  var calls: [String] = []

  init(
    percent: Int, ignoreWrites: Bool = false, writeStatus: Int32 = 0, readOverride: String? = nil
  ) {
    self.percent = percent
    self.ignoreWrites = ignoreWrites
    self.writeStatus = writeStatus
    self.readOverride = readOverride
  }

  func run(script: String) async throws -> DeviceScriptResult {
    calls.append(script)
    if script == "get alert volume of (get volume settings)" {
      return DeviceScriptResult(status: 0, output: readOverride ?? "\(percent)\n")
    }
    let prefix = "set volume alert volume "
    guard script.hasPrefix(prefix), let requested = Int(script.dropFirst(prefix.count)) else {
      return DeviceScriptResult(status: 1, output: "Unexpected unit-test script.")
    }
    if writeStatus != 0 { return DeviceScriptResult(status: writeStatus, output: "Script denied.") }
    if !ignoreWrites { percent = requested }
    return DeviceScriptResult(status: 0, output: "")
  }
}

private actor BackendManualClock {
  private var now = Duration.zero
  private var sleepers:
    [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
  private var barriers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var sleepCount = 0

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        sleepers[id] = (now + duration, continuation)
        sleepCount += 1
        let ready = barriers.filter { $0.count <= sleepCount }
        barriers.removeAll { $0.count <= sleepCount }
        for barrier in ready { barrier.continuation.resume() }
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func waitForSleepCount(_ count: Int) async {
    guard sleepCount < count else { return }
    await withCheckedContinuation { barriers.append((count, $0)) }
  }

  func advance(by duration: Duration) {
    now += duration
    let ready = sleepers.filter { $0.value.deadline <= now }
    for (id, sleeper) in ready {
      sleepers.removeValue(forKey: id)
      sleeper.continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}
