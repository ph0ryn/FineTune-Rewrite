import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("App composition: System alert silencing")
@MainActor
struct SystemAlertSilencingTests {
  @Test("Only a software mute of the system-sounds device needs the OS alert mirror")
  func policy() {
    #expect(!SystemAlertSilencing.shouldSilence(nil))
    #expect(
      !SystemAlertSilencing.shouldSilence(
        SystemAlertSilencingTarget(deviceUID: "speaker", tier: .hardware, isMuted: true)))
    #expect(
      !SystemAlertSilencing.shouldSilence(
        SystemAlertSilencingTarget(deviceUID: "speaker", tier: .ddc, isMuted: true)))
    #expect(
      !SystemAlertSilencing.shouldSilence(
        SystemAlertSilencingTarget(deviceUID: "speaker", tier: .software, isMuted: false)))
    #expect(
      SystemAlertSilencing.shouldSilence(
        SystemAlertSilencingTarget(deviceUID: "speaker", tier: .software, isMuted: true)))
  }

  @Test("A software mute saves and zeroes the alert volume; unmuting restores it")
  func muteRoundTrip() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(!fixture.silencing.isSilenced)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.silencing.isSilenced && fixture.silencing.lastError == nil)
    #expect(fixture.alertVolume.observedVolume == 0)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.8)
    #expect(fixture.scripts.currentPercent == 0)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: false))
    await fixture.silencing.awaitTransitions()
    #expect(!fixture.silencing.isSilenced)
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.scripts.currentPercent == 80)
  }

  @Test("Hardware and DDC mutes stay passive and repeated projections do no work")
  func passiveTiers() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()

    for tier in [VolumeControlTier.hardware, .ddc] {
      let target = SystemAlertSilencingTarget(deviceUID: "speaker", tier: tier, isMuted: true)
      fixture.silencing.update(target: target)
      fixture.silencing.update(target: target)
      await fixture.silencing.awaitTransitions()
      #expect(!fixture.silencing.isSilenced && fixture.silencing.lastError == nil)
    }
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.scripts.calls.allSatisfy { $0.hasPrefix("get ") })
  }

  @Test("An interrupted silencing is restored before the current mute is captured again")
  func interruptedRestoreRunsFirst() async {
    let fixture = SilencingFixture(percent: 0)
    defer { fixture.cleanUp() }
    fixture.settings.setAlertVolumeBeforeMuteSilencing(0.5)

    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    #expect(fixture.alertVolume.observedVolume == 0.5)
    #expect(fixture.scripts.currentPercent == 50)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(!fixture.silencing.isSilenced)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.silencing.isSilenced)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.5)
    #expect(fixture.scripts.currentPercent == 0)
  }

  @Test("A rejected silence write keeps the alert volume and reports the failure")
  func rejectedSilence() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.scripts.setWriteStatus(1)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(!fixture.silencing.isSilenced)
    #expect(fixture.silencing.lastError != nil)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(fixture.scripts.currentPercent == 80)
  }

  @Test("Will-terminate restores the saved alert volume without awaiting")
  func terminationRestore() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.scripts.currentPercent == 0)

    fixture.silencing.prepareForTermination()
    #expect(fixture.scripts.currentPercent == 80)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.8)
    #expect(!fixture.silencing.isSilenced)
  }

  @Test("Stopping the silencing owner restores an active mute")
  func stopRestores() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.scripts.currentPercent == 0)

    await fixture.silencing.stop()
    #expect(fixture.scripts.currentPercent == 80)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
  }
}

@Suite("App composition: DeviceControlModel and DeviceInspectorModel wiring", .serialized)
@MainActor
struct DeviceControlWiringTests {
  @Test("Seeded device projection before start performs zero HAL queries")
  func projectionBeforeStart() {
    let rig = DeviceWiringFixture(useLiveDetection: true)
    defer { rig.cleanUp() }
    let rows = rig.model.outputDevices
    #expect(rows.map(\.id) == ["speaker", "other"])
    #expect(rows.allSatisfy { $0.volume == nil && !$0.canSetVolume && !$0.canSetMute })
    #expect(rows.allSatisfy { $0.automaticBackend == nil })
    #expect(rig.hal.queries == 0)
  }

  @Test("AudioController device commands route through DeviceControlModel to HAL and preferences")
  func controllerToDeviceControlModelWiring() async {
    let rig = DeviceWiringFixture()
    defer { rig.cleanUp() }
    #expect(rig.hal.reads == 0 && rig.hal.writes.isEmpty)
    rig.start()
    rig.hal.writes.removeAll()

    rig.controller.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.6))
    #expect(rig.output.volumes[10] == 0.6 && rig.model.outputDevices.first?.volume == 0.6)

    rig.controller.perform(.setDeviceGain(scope: .input, uid: "mic", gain: 0.4))
    #expect(rig.model.inputDevices.first?.volume == 0.4)
    #expect(
      rig.hal.writes.suffix(2).map(\.selector) == [
        kAudioDevicePropertyMute, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      ])

    rig.controller.perform(.setDefaultDevice(scope: .input, uid: "mic"))
    rig.controller.perform(.setDefaultDevice(scope: .output, uid: "other"))
    #expect(rig.preferences.selected == ["mic"] && rig.settings.preferredInputDeviceUID == "mic")
    #expect(rig.preferences.selectedOutputs == ["other"] && rig.output.defaultDeviceUID == "other")

    rig.controller.perform(.setDevicePriority(scope: .output, connectedUIDs: ["other", "speaker"]))
    rig.controller.perform(.setDeviceHidden(scope: .output, uid: "speaker", hidden: true))
    #expect(rig.model.outputDevices.map(\.id) == ["other", "speaker"])
    #expect(rig.model.outputDevices.last?.isHidden == true)

    rig.hal.failWrites = true
    rig.controller.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.8))
    #expect(rig.controller.commandFailure != nil && rig.model.lastError != nil)
    await rig.stop()
    #expect(await rig.asyncPorts.closes == 1)
    #expect(rig.provider.starts == 0 && rig.provider.stops == 0)
  }

  @Test(
    "Manual system sounds stay separate from default output, and follow-default uses shared flag")
  func systemSoundActions() async {
    let rig = DeviceWiringFixture()
    defer { rig.cleanUp() }
    rig.start()
    rig.model.backendActions.setSystemOutput("other")
    #expect(
      rig.model.backend.systemOutputUID == "other" && !rig.settings.isSystemSoundsFollowingDefault)
    #expect(rig.output.defaultDeviceUID == "speaker")

    let defaultKey = WiringHAL.Key(
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

  @Test("DeviceInspectorModel observes sample-rate and hog changes and stops cleanly")
  func inspectorLiveObservations() {
    let hal = WiringHAL()
    hal.prepareInspector(device: 999, rate: 48_000, hogOwner: -1, input: true)
    var lookups = 0
    let device = AudioDevice(
      id: 999, uid: "unit-device", name: "Unit microphone", icon: nil, supportsAutoEQ: false)
    let model = DeviceInspectorModel(
      device: device, transport: .usb, isInput: true, reader: hal, writer: hal, observer: hal,
      resolveUID: { uid in
        #expect(uid == "unit-device")
        lookups += 1
        return 999
      })
    #expect(hal.reads == 0 && lookups == 0 && hal.activeObservations == 0)
    model.start()
    model.start()
    #expect(model.info?.sampleRate == 48_000)
    #expect(hal.activeObservations == 2)
    hal.prepareInspector(device: 999, rate: 44_100, hogOwner: 123, input: true)
    hal.emit(kAudioDevicePropertyNominalSampleRate)
    #expect(model.info?.sampleRate == 44_100 && model.info?.hogModeOwner == 123)
    #expect(model.error == nil)
    let callbacks = hal.callbacks.map(\.callback)
    model.stop()
    model.stop()
    let reads = hal.reads
    for callback in callbacks { callback() }
    #expect(hal.reads == reads && hal.activeObservations == 0)
  }

  @Test("DeviceInspectorModel writes resolve the current UID and surface unavailability errors")
  func inspectorUIDAndWriteFailure() {
    let hal = WiringHAL()
    hal.prepareInspector(device: 1001, rate: 48_000, hogOwner: -1, input: false)
    var available = true
    let device = AudioDevice(
      id: 999, uid: "unit-device", name: "Unit speaker", icon: nil, supportsAutoEQ: false)
    let model = DeviceInspectorModel(
      device: device, transport: .usb, reader: hal, writer: hal, observer: hal,
      resolveUID: { _ in
        guard available else { throw DeviceBackendError.unavailableDevice("unit-device") }
        return 1001
      })
    model.start()
    model.selectSampleRate(44_100)
    #expect(hal.writtenObjects == [1001])
    #expect(model.info?.sampleRate == 44_100)
    available = false
    model.selectSampleRate(96_000)
    #expect(hal.writtenObjects == [1001] && model.error != nil)
    #expect(model.info?.sampleRate == 44_100)
    model.stop()
  }
}

@MainActor
private final class SilencingFixture {
  let directory: URL
  let scripts: AlertVolumeScripts
  let settings: SettingsManager
  let alertVolume: AlertVolumeBackend
  let silencing: SystemAlertSilencing

  init(percent: Int = 80) {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "system-alert-silencing-\(UUID())")
    scripts = AlertVolumeScripts(percent: percent)
    settings = SettingsManager(
      directory: directory, launchAtLoginService: SilencingLoginService())
    alertVolume = AlertVolumeBackend(
      scriptRunner: scripts, clock: DeviceBackendClock { _ in },
      blockingScript: { [scripts] script in scripts.runBlocking(script: script) })
    silencing = SystemAlertSilencing(alertVolume: alertVolume, settings: settings)
  }

  func cleanUp() {
    precondition(directory.lastPathComponent.hasPrefix("system-alert-silencing-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class SilencingLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

private final class AlertVolumeScripts: DeviceScriptRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var percent: Int
  private var writeStatus: Int32 = 0
  private var recorded: [String] = []

  init(percent: Int) { self.percent = percent }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var currentPercent: Int {
    lock.lock()
    defer { lock.unlock() }
    return percent
  }

  func setWriteStatus(_ status: Int32) {
    lock.lock()
    writeStatus = status
    lock.unlock()
  }

  func run(script: String) async throws -> DeviceScriptResult { perform(script) }
  func runBlocking(script: String) -> DeviceScriptResult { perform(script) }

  private func perform(_ script: String) -> DeviceScriptResult {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(script)
    if script == "get alert volume of (get volume settings)" {
      return DeviceScriptResult(status: 0, output: "\(percent)\n")
    }
    let prefix = "set volume alert volume "
    guard script.hasPrefix(prefix), let requested = Int(script.dropFirst(prefix.count)) else {
      return DeviceScriptResult(status: 1, output: "Unexpected unit-test script.")
    }
    if writeStatus != 0 {
      return DeviceScriptResult(status: writeStatus, output: "Script denied.")
    }
    percent = requested
    return DeviceScriptResult(status: 0, output: "")
  }
}

@MainActor
private final class DeviceWiringFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "device-wiring-\(UUID())")
  let provider = WiringDevices()
  let hal = WiringHAL()
  let asyncPorts = WiringAsyncPorts()
  let preferences = WiringPreferences()
  let settings: SettingsManager
  let output: CoreAudioDeviceVolumeAdapter
  let model: DeviceControlModel
  let controller: AudioController

  init(useLiveDetection: Bool = false) {
    settings = SettingsManager(directory: directory, launchAtLoginService: hal)
    let detector: (@MainActor (AudioDeviceID) -> VolumeControlTier)?
    if useLiveDetection { detector = nil } else { detector = { _ in .hardware } }
    output = CoreAudioDeviceVolumeAdapter(
      deviceProvider: provider, settingsManager: settings, autoDetectedBackend: detector,
      reader: hal, writer: hal, observer: hal,
      resolveUID: { [provider] uid in
        guard let device = provider.device(for: uid) ?? provider.inputDevice(for: uid) else {
          throw DeviceBackendError.unavailableDevice(uid)
        }
        return device.id
      })
    let clock = DeviceBackendClock { _ in try Task.checkCancellation() }
    model = DeviceControlModel(
      settings: settings, devices: provider, output: output,
      input: InputDeviceBackend(deviceProvider: provider, reader: hal, writer: hal, observer: hal),
      systemSounds: SystemSoundBackend(
        deviceProvider: provider, reader: hal, writer: hal, observer: hal),
      alertVolume: AlertVolumeBackend(scriptRunner: asyncPorts, clock: clock),
      bluetooth: BluetoothDeviceBackend(transport: asyncPorts, clock: clock),
      ddc: DDCVolumeBackend(
        transport: asyncPorts, preferences: settings, candidates: { [] },
        displayChanges: WiringDisplayChanges(), clock: clock),
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

  func cleanUp() {
    precondition(directory.lastPathComponent.hasPrefix("device-wiring-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class WiringPreferences {
  var selected: [String] = []
  var changes = 0
  var selectedOutputs: [String] = []
  var outputChanges = 0
}

@MainActor
private final class WiringDevices: AudioDeviceProviding {
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

nonisolated private final class WiringHAL: AudioDevicePropertyReading,
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
  var writtenObjects: [AudioDeviceID] = []
  var failWrites = false
  var failedReads: Set<Key> = []
  var isEnabled = false
  var values: [Key: Any] = [:]
  @MainActor var activeObservations = 0
  @MainActor var callbacks:
    [(selector: AudioObjectPropertySelector, callback: @MainActor @Sendable () -> Void)] = []

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

  func prepareInspector(device: AudioDeviceID, rate: Double, hogOwner: Int32, input: Bool) {
    let global = kAudioObjectPropertyScopeGlobal
    values[Key(object: device, selector: kAudioDevicePropertyNominalSampleRate, scope: global)] =
      rate
    values[Key(object: device, selector: kAudioDevicePropertyHogMode, scope: global)] = hogOwner
    values[
      Key(object: device, selector: kAudioDevicePropertyAvailableNominalSampleRates, scope: global)] =
      [AudioValueRange(mMinimum: rate, mMaximum: rate)]
    values[
      Key(
        object: device, selector: kAudioDevicePropertyStreams,
        scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)] = [
        AudioStreamID
      ]()
  }

  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> Value {
    reads += 1
    queries += 1
    guard !failedReads.contains(Key(object: object, selector: selector, scope: scope)),
      let value = values[Key(object: object, selector: selector, scope: scope)] as? Value
    else { throw WiringFailure.read }
    return value
  }

  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> [Value] {
    reads += 1
    queries += 1
    guard let value = values[Key(object: object, selector: selector, scope: scope)] as? [Value]
    else { throw WiringFailure.read }
    return value
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
    if selector == kAudioDevicePropertyNominalSampleRate { return true }
    return values[Key(object: object, selector: selector, scope: scope)] != nil
  }

  @MainActor
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    value: Value
  ) throws {
    let key = Key(object: object, selector: selector, scope: scope)
    writes.append(key)
    writtenObjects.append(object)
    if failWrites { throw WiringFailure.write }
    values[key] = value
  }

  @MainActor
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    activeObservations += 1
    callbacks.append((selector, onChange))
    return DevicePropertyObservation { [weak self] in self?.activeObservations -= 1 }
  }

  @MainActor
  func emit(_ selector: AudioObjectPropertySelector) {
    for registration in callbacks where registration.selector == selector {
      registration.callback()
    }
  }

  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

private actor WiringAsyncPorts: DeviceScriptRunning, BluetoothDeviceTransport, DDCDisplayTransport {
  var closes = 0
  func run(script: String) async throws -> DeviceScriptResult {
    DeviceScriptResult(status: 0, output: "0\n")
  }
  func snapshot() async throws -> BluetoothTransportSnapshot {
    BluetoothTransportSnapshot(isPoweredOn: true, peers: [])
  }
  func connect(id: String) async throws { throw WiringFailure.write }
  @MainActor func observePowerChanges(_ onChange: @escaping @MainActor @Sendable () -> Void)
    -> DevicePropertyObservation
  { DevicePropertyObservation {} }
  func discover() async throws -> [DDCDisplaySnapshot] { [] }
  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    throw WiringFailure.write
  }
  func readVolume(displayID: UUID) async throws -> DDCVCPValue { throw WiringFailure.read }
  func close() async throws { closes += 1 }
}

@MainActor
private struct WiringDisplayChanges: DisplayParameterObserving {
  func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    DevicePropertyObservation {}
  }
}

private enum WiringFailure: Error { case read, write }
