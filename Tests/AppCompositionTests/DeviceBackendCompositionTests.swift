import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Observation
import Testing

@testable import FineTune

@Suite("Actual device composition and common commands", .serialized)
@MainActor
struct DeviceBackendCompositionTests {
  @Test(
    "Seeded-device projection before start performs zero HAL queries without a detector override")
  func projectionBeforeStart() {
    let rig = DeviceCompositionFixture(useLiveDetection: true)
    let rows = rig.model.outputDevices
    #expect(rows.map(\.id) == ["speaker", "other"])
    #expect(rows.allSatisfy { $0.volume == nil && !$0.canSetVolume && !$0.canSetMute })
    #expect(rig.hal.queries == 0)
    #expect(rows.allSatisfy { $0.automaticBackend == nil })
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: nil))
  }

  @Test("Common raw media gain preserves mute, while a positive UI edit unmutes")
  func rawMediaGain() async {
    let rig = DeviceCompositionFixture()
    rig.hal.values[
      CompositionHAL.Key(
        object: 10, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)] =
      UInt32(1)
    rig.start()
    rig.hal.writes.removeAll()
    rig.controller.perform(.setRawDeviceGain(scope: .output, uid: "speaker", gain: 0.6))
    #expect(rig.controller.commandFailure == nil && rig.output.volumes[10] == 0.6)
    #expect(rig.output.muteStates[10] == true)
    rig.controller.perform(.setRawDeviceGain(scope: .input, uid: "mic", gain: 0.4))
    #expect(rig.controller.commandFailure == nil && rig.model.inputDevices.first?.volume == 0.4)
    #expect(rig.model.inputDevices.first?.isMuted == true)
    #expect(
      rig.hal.writes.count == 2
        && rig.hal.writes.allSatisfy {
          $0.selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        })
    rig.controller.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.7))
    #expect(rig.output.muteStates[10] == false && rig.output.volumes[10] == 0.7)
    let writes = rig.hal.writes.count
    rig.controller.perform(.setRawDeviceGain(scope: .input, uid: "mic", gain: .nan))
    #expect(rig.controller.commandFailure != nil && rig.hal.writes.count == writes)
    await rig.stop()
  }

  @Test(
    "Constructor is zero HAL IO and common input edits are linear, unmuting before the new gain")
  func commonInputCommand() async {
    let rig = DeviceCompositionFixture()
    #expect(rig.hal.reads == 0 && rig.hal.writes.isEmpty)
    rig.start()
    rig.hal.writes.removeAll()
    rig.controller.perform(.setDeviceGain(scope: .input, uid: "mic", gain: 0.4))
    #expect(rig.controller.commandFailure == nil)
    #expect(rig.model.inputDevices.first?.volume == 0.4)
    #expect(
      rig.hal.writes.map(\.selector) == [
        kAudioDevicePropertyMute, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      ])
    #expect(rig.hal.writes.allSatisfy { $0.scope == kAudioObjectPropertyScopeInput })
    await rig.stop()
  }

  @Test(
    "Common device operations use the same output owner and delegate preferred input to Control")
  func commonOutputAndInputPreference() async {
    let rig = DeviceCompositionFixture()
    rig.start()
    rig.controller.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.6))
    #expect(rig.output.volumes[10] == 0.6 && rig.model.outputDevices.first?.volume == 0.6)
    rig.controller.perform(.setDefaultDevice(scope: .input, uid: "mic"))
    #expect(rig.preferences.selected == ["mic"])
    #expect(rig.settings.preferredInputDeviceUID == "mic")
    rig.controller.perform(.setDefaultDevice(scope: .output, uid: "other"))
    #expect(rig.preferences.selectedOutputs == ["other"])
    #expect(rig.controller.commandFailure == nil && rig.output.defaultDeviceUID == "other")
    await rig.stop()
  }

  @Test(
    "Manual system sounds stay separate from default output, and follow-default uses the shared flag"
  )
  func systemSoundActions() async {
    let rig = DeviceCompositionFixture()
    rig.start()
    rig.model.backendActions.setSystemOutput("other")
    #expect(
      rig.model.backend.systemOutputUID == "other" && !rig.settings.isSystemSoundsFollowingDefault)
    #expect(rig.output.defaultDeviceUID == "speaker")
    let defaultKey = CompositionHAL.Key(
      object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice,
      scope: kAudioObjectPropertyScopeGlobal)
    rig.hal.failedReads.insert(defaultKey)
    rig.output.refreshOutputDeviceStates()
    rig.model.backendActions.setSystemFollowDefault()
    #expect(rig.model.backend.systemOutputUID == "other" && rig.model.lastError != nil)
    rig.hal.failedReads.remove(defaultKey)
    rig.output.refreshOutputDeviceStates()
    rig.model.devicesDidChange()
    #expect(
      rig.model.backend.systemOutputUID == "speaker" && rig.settings.isSystemSoundsFollowingDefault)
    await rig.stop()
  }

  @Test(
    "Priority preserves disconnected wishes and hiding does not remove a default device projection")
  func savedDevicePresentation() async {
    let rig = DeviceCompositionFixture()
    rig.settings.setDevicePriorityOrder(["old", "speaker", "gone", "other"])
    rig.start()
    rig.controller.perform(.setDevicePriority(scope: .output, connectedUIDs: ["other", "speaker"]))
    rig.controller.perform(.setDeviceHidden(scope: .output, uid: "speaker", hidden: true))
    #expect(rig.settings.devicePriorityOrder == ["old", "other", "speaker", "gone"])
    #expect(rig.preferences.outputChanges == 1)
    #expect(rig.model.outputDevices.map(\.id) == ["other", "speaker"])
    #expect(
      rig.model.outputDevices.last?.isHidden == true
        && rig.model.outputDevices.last?.isDefault == true)
    await rig.stop()
  }

  @Test(
    "Bluetooth transient error clears in the actual model instead of being latched a second time")
  func transientBluetoothFailure() async throws {
    let gate = CompositionErrorClearGate()
    let rig = DeviceCompositionFixture(clock: DeviceBackendClock { try await gate.sleep($0) })
    rig.start()
    rig.model.backendActions.connectBluetooth("missing")
    do {
      try await gate.waitForRequest(timeout: .seconds(5))
      #expect(rig.model.backend.bluetooth.error != nil)
      let errorCleared = CompositionGateSignal(waitedFor: "Bluetooth lastError to clear")
      withObservationTracking {
        _ = rig.bluetooth.lastError
      } onChange: {
        errorCleared.succeed()
      }
      Task { await gate.release() }
      try await errorCleared.wait(timeout: .seconds(5))
    } catch {
      // Failure-path only: an unwinding wait must not leave the model and backend tasks stranded
      // behind the intentionally held 4-second sleep. The original timeout/cancellation is kept.
      await gate.release()
      await rig.stop()
      throw error
    }
    #expect(rig.model.backend.bluetooth.error == nil)
    #expect(rig.model.lastError == nil)
    await rig.stop()
  }

  @Test("HAL failure reaches common command error and row projection without inventing a new gain")
  func truthfulFailure() async {
    let rig = DeviceCompositionFixture()
    rig.start()
    rig.hal.failWrites = true
    rig.controller.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.8))
    #expect(rig.controller.commandFailure != nil && rig.model.lastError != nil)
    #expect(
      rig.model.outputDevices.first?.volume == 0.25 && rig.model.outputDevices.first?.error != nil)
    await rig.stop()
    #expect(await rig.asyncPorts.closes == 1)
    #expect(rig.provider.starts == 0 && rig.provider.stops == 0)
  }

  @Test("A software system-sounds mute silences OS alerts and unmuting restores them")
  func softwareMuteSilencesAlerts() async {
    let rig = DeviceCompositionFixture(outputTier: .software)
    rig.start()
    await rig.model.awaitAlertSilencing()
    #expect(rig.model.backend.alertVolume == 0.26 && !rig.model.backend.alertVolumeSilenced)
    rig.controller.perform(.setDeviceMuted(scope: .output, uid: "speaker", muted: true))
    await rig.model.awaitAlertSilencing()
    #expect(rig.model.backend.alertVolumeSilenced && rig.model.backend.alertVolume == 0)
    #expect(rig.settings.alertVolumeBeforeMuteSilencing == 0.26)
    #expect(await rig.asyncPorts.alertPercent == 0)
    rig.controller.perform(.setDeviceMuted(scope: .output, uid: "speaker", muted: false))
    await rig.model.awaitAlertSilencing()
    #expect(!rig.model.backend.alertVolumeSilenced && rig.model.backend.alertVolume == 0.26)
    #expect(rig.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(await rig.asyncPorts.alertPercent == 26)
    await rig.stop()
    #expect(rig.settings.alertVolumeBeforeMuteSilencing == nil)
  }

  @Test("A hardware mute does not touch the OS alert volume")
  func hardwareMuteLeavesAlertsAlone() async {
    let rig = DeviceCompositionFixture()
    rig.start()
    await rig.model.awaitAlertSilencing()
    rig.controller.perform(.setDeviceMuted(scope: .output, uid: "speaker", muted: true))
    await rig.model.awaitAlertSilencing()
    #expect(!rig.model.backend.alertVolumeSilenced)
    #expect(rig.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(await rig.asyncPorts.alertScripts.filter { $0.hasPrefix("set ") }.isEmpty)
    await rig.stop()
  }
}

@MainActor
private final class DeviceCompositionFixture {
  let provider = CompositionDevices()
  let hal = CompositionHAL()
  let asyncPorts = CompositionAsyncPorts()
  let preferences = CompositionInputPreferences()
  let settings: SettingsManager
  let output: CoreAudioDeviceVolumeAdapter
  let bluetooth: BluetoothDeviceBackend
  let model: DeviceControlModel
  let controller: AudioController

  init(
    clock testClock: DeviceBackendClock? = nil, useLiveDetection: Bool = false,
    outputTier: VolumeControlTier = .hardware
  ) {
    settings = SettingsManager(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "device-composition-\(UUID())"),
      launchAtLoginService: hal)
    let detector: (@MainActor (AudioDeviceID) -> VolumeControlTier)?
    if useLiveDetection { detector = nil } else { detector = { _ in outputTier } }
    output = CoreAudioDeviceVolumeAdapter(
      deviceProvider: provider, settingsManager: settings,
      autoDetectedBackend: detector,
      reader: hal, writer: hal, observer: hal,
      resolveUID: { [provider] uid in
        guard let device = provider.device(for: uid) ?? provider.inputDevice(for: uid) else {
          throw DeviceBackendError.unavailableDevice(uid)
        }
        return device.id
      })
    let clock = testClock ?? DeviceBackendClock { _ in try Task.checkCancellation() }
    bluetooth = BluetoothDeviceBackend(transport: asyncPorts, clock: clock)
    model = DeviceControlModel(
      settings: settings, devices: provider, output: output,
      input: InputDeviceBackend(deviceProvider: provider, reader: hal, writer: hal, observer: hal),
      systemSounds: SystemSoundBackend(
        deviceProvider: provider, reader: hal, writer: hal, observer: hal),
      alertVolume: AlertVolumeBackend(scriptRunner: asyncPorts, clock: clock),
      bluetooth: bluetooth,
      ddc: DDCVolumeBackend(
        transport: asyncPorts, preferences: settings, candidates: { [] },
        displayChanges: CompositionDisplayChanges(), clock: clock),
      reader: hal,
      selectPreferredInput: { [preferences, settings] uid in
        preferences.selected.append(uid)
        settings.setPreferredInputDeviceUID(uid)
      }, inputPreferencesDidChange: { [preferences] in preferences.changes += 1 },
      selectDefaultOutput: { [preferences, provider, output] uid in
        preferences.selectedOutputs.append(uid)
        guard let device = provider.device(for: uid), output.setDefaultDevice(device.id) else {
          throw output.lastError ?? DeviceBackendError.unavailableDevice(uid)
        }
      }, outputPreferencesDidChange: { [preferences] in preferences.outputChanges += 1 })
    controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved }, deviceCommand: model.perform)
  }
  func start() {
    output.start()
    model.start()
  }
  func stop() async {
    await model.stop()
    output.stop()
  }
}

@MainActor
private final class CompositionInputPreferences {
  var selected: [String] = []
  var changes = 0
  var selectedOutputs: [String] = []
  var outputChanges = 0
}

@MainActor
private final class CompositionDevices: AudioDeviceProviding {
  var outputDevices = [device(10, "speaker"), device(11, "other")]
  var inputDevices = [device(20, "mic")]
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

nonisolated private final class CompositionHAL: AudioDevicePropertyReading,
  AudioDevicePropertyWriting, AudioDevicePropertyObserving, LaunchAtLoginService
{
  struct Key: Hashable {
    let object: UInt32
    let selector: UInt32
    let scope: UInt32
  }
  var reads = 0
  var queries = 0
  var writes: [Key] = []
  var failWrites = false
  var failedReads: Set<Key> = []
  var isEnabled = false
  var values: [Key: Any] = [:]
  init() {
    for selector in [
      kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice,
    ] {
      values[Key(object: .system, selector: selector, scope: kAudioObjectPropertyScopeGlobal)] =
        AudioDeviceID(10)
    }
    values[
      Key(
        object: .system, selector: kAudioHardwarePropertyDefaultInputDevice,
        scope: kAudioObjectPropertyScopeGlobal)] = AudioDeviceID(20)
    for (id, scope, volume, muted) in [
      (UInt32(10), kAudioObjectPropertyScopeOutput, Float(0.25), UInt32(0)),
      (11, kAudioObjectPropertyScopeOutput, 0.5, 0), (20, kAudioObjectPropertyScopeInput, 0.3, 1),
    ] {
      values[
        Key(
          object: id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
      ] = volume
      values[Key(object: id, selector: kAudioDevicePropertyMute, scope: scope)] = muted
    }
  }
  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> Value {
    reads += 1
    queries += 1
    guard !failedReads.contains(Key(object: object, selector: selector, scope: scope)),
      let value = values[Key(object: object, selector: selector, scope: scope)] as? Value
    else {
      throw CompositionFailure.read
    }
    return value
  }
  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> [Value] {
    queries += 1
    throw CompositionFailure.read
  }
  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    queries += 1
    return values[Key(object: object, selector: selector, scope: scope)] != nil
  }
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool {
    queries += 1
    return values[Key(object: object, selector: selector, scope: scope)] != nil
  }
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    value: Value
  ) throws {
    let key = Key(object: object, selector: selector, scope: scope)
    writes.append(key)
    if failWrites { throw CompositionFailure.write }
    values[key] = value
  }
  @MainActor
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation { DevicePropertyObservation {} }
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

private actor CompositionAsyncPorts: DeviceScriptRunning, BluetoothDeviceTransport,
  DDCDisplayTransport
{
  var closes = 0
  private(set) var alertPercent: Int
  private(set) var alertScripts: [String] = []

  init(alertPercent: Int = 26) {
    self.alertPercent = alertPercent
  }

  func run(script: String) async throws -> DeviceScriptResult {
    alertScripts.append(script)
    if script == "get alert volume of (get volume settings)" {
      return DeviceScriptResult(status: 0, output: "\(alertPercent)\n")
    }
    let prefix = "set volume alert volume "
    guard script.hasPrefix(prefix), let requested = Int(script.dropFirst(prefix.count)) else {
      return DeviceScriptResult(status: 1, output: "Unexpected unit-test script.")
    }
    alertPercent = requested
    return DeviceScriptResult(status: 0, output: "")
  }
  func snapshot() async throws -> BluetoothTransportSnapshot {
    BluetoothTransportSnapshot(isPoweredOn: true, peers: [])
  }
  func connect(id: String) async throws { throw CompositionFailure.write }
  @MainActor func observePowerChanges(_ onChange: @escaping @MainActor @Sendable () -> Void)
    -> DevicePropertyObservation
  { DevicePropertyObservation {} }
  func discover() async throws -> [DDCDisplaySnapshot] { [] }
  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    throw CompositionFailure.write
  }
  func readVolume(displayID: UUID) async throws -> DDCVCPValue { throw CompositionFailure.read }
  func close() async throws { closes += 1 }
}
@MainActor
private struct CompositionDisplayChanges: DisplayParameterObserving {
  func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    DevicePropertyObservation {}
  }
}
private enum CompositionFailure: Error { case read, write }

/// Bounded wait that failed because the gate's expected event never arrived.
private struct CompositionGateTimeout: Error, CustomStringConvertible {
  let waitedFor: String
  let timeout: Duration
  var description: String { "Timed out after \(timeout) waiting for \(waitedFor)" }
}

/// Single-shot suspension completed by a gate event, an explicit deadline, or cancellation.
/// The first completion wins, so a late observation callback cannot resume a checked
/// continuation twice.
private final class CompositionGateSignal: @unchecked Sendable {
  private let lock = NSLock()
  private let waitedFor: String
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  init(waitedFor: String) { self.waitedFor = waitedFor }

  /// Waits for a held operation that only `release()` or cancellation ends.
  func wait() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation)
      }
    } onCancel: {
      complete(.failure(CancellationError()))
    }
  }

  /// Waits no longer than the deadline, then throws `CompositionGateTimeout`.
  func wait(timeout: Duration) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await self.wait() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw CompositionGateTimeout(waitedFor: self.waitedFor, timeout: timeout)
      }
      let result = await group.nextResult()
      group.cancelAll()
      while await group.nextResult() != nil {}
      try result?.get()
    }
  }

  func succeed() { complete(.success(())) }

  private func install(_ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    if let result = self.result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  private func complete(_ result: Result<Void, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

/// One explicit error-clear barrier, not a second virtual scheduler.
private actor CompositionErrorClearGate {
  private var request: CompositionGateSignal?
  private var requestWaiters: [CompositionGateSignal] = []

  func sleep(_ duration: Duration) async throws {
    try Task.checkCancellation()
    guard duration == .seconds(4) else { return }
    let signal = CompositionGateSignal(waitedFor: "the held 4-second error-clear sleep")
    request = signal
    defer {
      if request === signal { request = nil }
    }
    for waiter in requestWaiters { waiter.succeed() }
    requestWaiters.removeAll()
    try await signal.wait()
    try Task.checkCancellation()
  }

  /// Bounded by an explicit deadline; a missing request fails instead of hanging.
  func waitForRequest(timeout: Duration) async throws {
    try Task.checkCancellation()
    if request != nil { return }
    let waiter = CompositionGateSignal(waitedFor: "the 4-second error-clear sleep to start")
    requestWaiters.append(waiter)
    defer { requestWaiters.removeAll { $0 === waiter } }
    try await waiter.wait(timeout: timeout)
  }

  /// Resumes exactly the held sleep so the backend can clear its published error.
  func release() {
    request?.succeed()
    request = nil
  }
}
