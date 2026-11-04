import AppKit
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("Actual Root presentation without live services")
@MainActor
struct RootPresentationTests {
  @Test("Construction and repeated snapshots only read the actual passive owners")
  func constructionAndSnapshotsArePassive() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let mixer = presentation.mixerSnapshot()
    let settings = presentation.settingsSnapshot()
    presentation.invalidate()
    #expect(presentation.mixerSnapshot().apps.isEmpty)
    #expect(mixer.outputDevices.map(\.id) == ["speaker"])
    #expect(mixer.inputDevices.map(\.id) == ["mic"])
    #expect(
      mixer.outputDevices.allSatisfy {
        $0.volume == nil && $0.isMuted == nil && !$0.canSetVolume && !$0.canSetMute
          && $0.automaticBackend == nil
      })
    #expect(!settings.isAccessibilityTrusted && !settings.isMediaKeyOffline)
    #expect(mixer.error == nil && settings.error == nil)
    #expect(mixer.captureNotice?.action == .requestPermission)
    let missingDescription = fixture.presentation(hasUsageDescription: false).mixerSnapshot()
    #expect(missingDescription.captureNotice?.action == nil)
    #expect(missingDescription.captureNotice?.message.contains("unavailable") == true)
    #expect(fixture.graph.settings === fixture.settings)
    #expect(fixture.graph.bindings.controller === fixture.graph.controller)
    #expect(fixture.graph.devices === fixture.devices && fixture.graph.volumes === fixture.output)
    await fixture.expectPassivePorts()
  }

  @Test("Snapshots read new real settings and stable live plus saved app identities without copies")
  func snapshotsReadThroughTheSameOwners() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    fixture.processes.apps = [
      fixture.app(id: 101, uid: "unit.live-b", name: "Shared"),
      fixture.app(id: 102, uid: "unit.live-a", name: "Shared"),
      fixture.app(id: 103, uid: "unit.saved", name: "Saved player"),
      fixture.app(id: 104, uid: "unit.ignored", name: "Ignored player"),
    ]
    // Real saved metadata comes from a previously observed app, not an invented inactive name.
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.perform(.setPinned(identifier: "unit.live-a", pinned: true))
    controller.perform(.setPinned(identifier: "unit.saved", pinned: true))
    #expect(controller.commandFailure == nil)
    controller.perform(.setIgnored(identifier: "unit.live-b", ignored: true))
    controller.perform(.setIgnored(identifier: "unit.ignored", ignored: true))
    #expect(controller.commandFailure == nil)
    controller.perform(.setGain(identifier: "unit.live-a", gain: 0.5))
    controller.perform(.setMuted(identifier: "unit.live-a", muted: true))
    controller.perform(.setGain(identifier: "unit.saved", gain: 0.25))
    controller.perform(
      .setRoute(identifier: "unit.saved", mode: .multi, uids: ["speaker", "gone"]))
    fixture.processes.apps.removeLast(2)
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()
    let halBeforeSnapshot = fixture.hal.calls
    let preset = fixture.settings.createUserPreset(name: "Saved curve", settings: .flat)
    var wishes = fixture.settings.appSettings
    wishes.explicitUserCaptureEnabled = true
    fixture.settings.updateAppSettings(wishes)
    fixture.trust.isTrusted = true
    fixture.mediaKeys.isOffline = true
    presentation.invalidate()

    let snapshot = presentation.mixerSnapshot()
    #expect(snapshot.apps.count == 4)
    #expect(
      Set(snapshot.apps.map(\.id)) == ["unit.live-a", "unit.live-b", "unit.saved", "unit.ignored"])
    #expect(snapshot.apps.filter(\.isActive).map(\.id) == ["unit.live-a", "unit.live-b"])
    let live = try #require(snapshot.apps.first { $0.id == "unit.live-a" })
    let saved = try #require(snapshot.apps.first { $0.id == "unit.saved" })
    #expect(live.gain == 0.5 && live.isMuted && live.isPinned)
    #expect(!saved.isActive && saved.isPinned && saved.gain == 0.25)
    #expect(saved.selectionMode == .multi && !saved.isFollowingDefault)
    #expect(saved.selectedDeviceUIDs == ["speaker", "gone"])
    #expect(snapshot.apps.first { $0.id == "unit.ignored" }?.isIgnored == true)
    #expect(snapshot.apps.filter { $0.id == "unit.live-b" }.count == 1)
    #expect(snapshot.userPresets.map(\.id) == [preset.id])
    #expect(snapshot.settings.explicitUserCaptureEnabled)
    let settings = presentation.settingsSnapshot()
    #expect(settings.settings.explicitUserCaptureEnabled)
    #expect(settings.isAccessibilityTrusted && settings.isMediaKeyOffline)
    // A saved wish and cached AX status are not a newly granted capture intent.
    #expect(controller.captureIntent == .none)
    #expect(snapshot.captureNotice?.action == .requestPermission)
    await fixture.expectPassivePorts(halBaseline: halBeforeSnapshot)
    print(
      "RootPresentation saved-app snapshot HAL: before=\(halBeforeSnapshot), after=\(fixture.hal.calls)"
    )

    fixture.processes.apps[1] = fixture.app(id: 202, uid: "unit.live-a", name: "Renamed")
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()
    let halBeforeRefresh = fixture.hal.calls
    let refreshed = presentation.mixerSnapshot()
    #expect(refreshed.apps.count == 4)
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.name == "Renamed")
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.gain == 0.5)
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.isMuted == true)
    await fixture.expectPassivePorts(halBaseline: halBeforeRefresh)
    print(
      "RootPresentation rebound snapshot HAL: before=\(halBeforeRefresh), after=\(fixture.hal.calls)"
    )
  }

  @Test("Eight device actions use the same Common port and failure notices retain their reasons")
  func deviceActionsAndFailureProjection() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let actions = presentation.deviceActions
    actions.setDefault(.input, "mic")
    actions.setVolume(.output, "speaker", 0.25)
    #expect(
      fixture.effects.commands == [
        .setDefaultDevice(scope: .input, uid: "mic"),
        .setDeviceGain(scope: .output, uid: "speaker", gain: 0.25),
      ])
    actions.setMute(.input, "mic", true)
    actions.setHidden(.output, "speaker", true)
    actions.setPriority(.input, ["mic", "gone"])
    actions.setIcon("speaker", "music.note")
    actions.setVolumeOverride("speaker", .software)
    actions.stepVolume(.output, "speaker", false, true)
    #expect(
      fixture.effects.commands == [
        .setDefaultDevice(scope: .input, uid: "mic"),
        .setDeviceGain(scope: .output, uid: "speaker", gain: 0.25),
        .setDeviceMuted(scope: .input, uid: "mic", muted: true),
        .setDeviceHidden(scope: .output, uid: "speaker", hidden: true),
        .setDevicePriority(scope: .input, connectedUIDs: ["mic", "gone"]),
        .setDeviceIcon(uid: "speaker", symbol: "music.note"),
        .setDeviceVolumeOverride(uid: "speaker", tier: .software),
        .stepDeviceVolume(scope: .output, uid: "speaker", isUp: false, shift: true),
      ])
    let reason = "Shared external observation unavailable"
    fixture.effects.commandFailure = AudioRouteFailure(
      kind: .unavailable, stage: "unit-device", message: reason)
    actions.setDefault(.output, "speaker")
    fixture.graph.controller.observeApplications([], failure: reason)
    fixture.graph.controller.observeOutputs([], defaultUID: nil, failure: reason)
    #expect(fixture.graph.controller.commandFailure?.message == reason)
    #expect(presentation.mixerSnapshot().error == reason)
    #expect(presentation.settingsSnapshot().error == reason)
    #expect(presentation.mixerSnapshot().captureNotice?.message == reason)
    #expect(presentation.mixerSnapshot().captureNotice?.action == nil)
    await fixture.expectPassivePorts()

    fixture.effects.commandFailure = nil
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.live", name: "Player")]
    fixture.graph.engine.ingestObservations()
    fixture.graph.controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      ], defaultUID: "speaker")
    fixture.graph.controller.perform(.requestCaptureStart)
    await fixture.graph.controller.waitForCurrentWork()
    #expect(fixture.effects.nativeResolutions == 1)
    #expect(fixture.graph.controller.knownPermissionDenied)
    // Explicit Engine ingestion above may query its external HAL port; VM reads may not add any.
    let halBeforeSnapshot = fixture.hal.calls
    let denied = presentation.mixerSnapshot()
    #expect(denied.captureNotice?.action == .openSettings)
    #expect(denied.captureNotice?.message.contains("denied") == true)
    #expect(denied.error?.contains("Unit capture denied before native I/O") == true)
    #expect(!presentation.settingsSnapshot().isAccessibilityTrusted)
    #expect(fixture.hal.calls == halBeforeSnapshot && fixture.hal.loginCalls == 0)
    print(
      "RootPresentation denied snapshot HAL: before=\(halBeforeSnapshot), after=\(fixture.hal.calls)"
    )
    #expect(fixture.effects.nativeResolutions == 1)
    #expect(await fixture.transport.calls == 0)
    await fixture.graph.controller.shutdown()
  }
}

@MainActor
private final class RootPresentationFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "FineTuneRootPresentation-\(UUID().uuidString)", isDirectory: true)
  let devices = PresentationDevices()
  let processes = PresentationProcesses()
  let hal = PresentationHAL()
  let transport = PresentationTransport()
  let trust = PresentationTrust()
  let mediaKeys = MediaKeyStatus()
  let effects = PresentationEffects()
  let settings: SettingsManager
  let output: CoreAudioDeviceVolumeAdapter
  let model: DeviceControlModel
  let native: NativeAudioRoutingRuntime
  let graph: ApplicationGraph
  let lifecycle: LifecycleCoordinator

  init() throws {
    settings = SettingsManager(directory: directory, launchAtLoginService: hal)
    let clock = DeviceBackendClock { _ in throw CancellationError() }
    let ddc = DDCVolumeBackend(
      transport: transport, preferences: settings, candidates: { [] },
      displayChanges: PresentationDisplayChanges(), clock: clock)
    output = CoreAudioDeviceVolumeAdapter(
      deviceProvider: devices, settingsManager: settings, reader: hal, writer: hal,
      observer: hal, ddcController: ddc)
    model = DeviceControlModel(
      settings: settings, devices: devices, output: output,
      input: InputDeviceBackend(deviceProvider: devices, reader: hal, writer: hal, observer: hal),
      systemSounds: SystemSoundBackend(
        deviceProvider: devices, reader: hal, writer: hal, observer: hal),
      alertVolume: AlertVolumeBackend(scriptRunner: transport, clock: clock),
      bluetooth: BluetoothDeviceBackend(transport: transport, clock: clock), ddc: ddc, reader: hal,
      selectPreferredInput: { _ in Issue.record("Projection must not select an input") },
      inputPreferencesDidChange: { Issue.record("Projection must not run input policy") },
      selectDefaultOutput: { _ in Issue.record("Projection must not select an output") },
      outputPreferencesDidChange: { Issue.record("Projection must not run output policy") })
    let effects = effects
    native = NativeAudioRoutingRuntime { _, _ in
      effects.nativeResolutions += 1
      // Exercise Control's public failure path, but never reach a native capture/TCC call.
      throw AudioRouteFailure(
        kind: .permissionDenied, stage: "unit-native-preflight",
        message: "Unit capture denied before native I/O")
    }
    graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache(),
        transport: transport),
      devices: devices, processes: processes, volumes: output, runtime: native,
      readOutputFailure: { nil }, readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { command in
        effects.commands.append(command)
        if let failure = effects.commandFailure { throw failure }
      })
    lifecycle = LifecycleCoordinator(
      settings: settings,
      ports: LifecyclePorts(
        start: { effects.starts += 1 }, shutdown: { effects.stops += 1 },
        suspendAudio: { Issue.record("Projection must not suspend audio") },
        resumeAudio: { Issue.record("Projection must not resume audio") },
        suspendInput: { Issue.record("Projection must not suspend input") },
        resumeInput: { Issue.record("Projection must not resume input") }))
  }

  func presentation(hasUsageDescription: Bool = true) -> RootPresentation {
    RootPresentation(
      graph: graph, devices: model, native: native, accessibility: trust,
      mediaKeyStatus: mediaKeys, lifecycle: lifecycle,
      hasCaptureUsageDescription: hasUsageDescription)
  }

  func app(id: pid_t, uid: String, name: String) -> AudioApp {
    AudioApp(
      id: id, processObjectIDs: [UInt32(id) + 700], name: name,
      icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: uid,
      processRevision: processes.revision)
  }

  func expectPassivePorts(halBaseline: Int = 0) async {
    #expect(hal.calls == halBaseline && hal.loginCalls == 0)
    #expect(devices.starts == 0 && processes.starts == 0)
    #expect(effects.starts == 0 && effects.stops == 0 && effects.nativeResolutions == 0)
    #expect(trust.refreshes == 0 && !model.isRunning && lifecycle.phase == .idle)
    #expect(await transport.calls == 0)
  }

  func cleanUp() {
    settings.flushSync()
    let base = FileManager.default.temporaryDirectory.standardizedFileURL
    precondition(directory.deletingLastPathComponent().standardizedFileURL == base)
    precondition(directory.lastPathComponent.hasPrefix("FineTuneRootPresentation-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class PresentationEffects {
  var commands: [AudioCommand] = []
  var commandFailure: AudioRouteFailure?
  var nativeResolutions = 0
  var starts = 0
  var stops = 0
}

@MainActor
private final class PresentationTrust: AccessibilityTrustProviding {
  var isTrusted = false
  var refreshes = 0
  func refresh() { refreshes += 1 }
}

@MainActor
private final class PresentationDevices: AudioDeviceObservationProviding {
  let outputDevices = [
    AudioDevice(
      id: 10, uid: "speaker", name: "Speaker", icon: nil,
      supportsAutoEQ: false, bindingRevision: 1)
  ]
  let inputDevices = [
    AudioDevice(
      id: 20, uid: "mic", name: "Microphone", icon: nil,
      supportsAutoEQ: false, bindingRevision: 1)
  ]
  var starts = 0
  var onObservationChanged: (() -> Void)?
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  var observation: AudioDeviceObservationSnapshot {
    AudioDeviceObservationSnapshot(
      outputDevices: outputDevices, inputDevices: inputDevices,
      health: .healthy, revision: 1)
  }
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  func start() { starts += 1 }
  func stop() { Issue.record("Projection must not stop discovery") }
}

@MainActor
private final class PresentationProcesses: AudioProcessObservationProviding {
  var apps: [AudioApp] = []
  var revision: UInt64 = 1
  var activeApps: [AudioApp] { apps }
  var starts = 0
  var onObservationChanged: (() -> Void)?
  var onAppsChanged: (([AudioApp]) -> Void)?
  var observation: AudioProcessObservationSnapshot {
    AudioProcessObservationSnapshot(activeApps: apps, health: .healthy, revision: revision)
  }
  func start() { starts += 1 }
  func stop() { Issue.record("Projection must not stop process discovery") }
}

nonisolated private final class PresentationHAL: AudioDevicePropertyReading,
  AudioDevicePropertyWriting, AudioDevicePropertyObserving, LaunchAtLoginService
{
  var calls = 0
  var loginCalls = 0
  var isEnabled: Bool {
    loginCalls += 1
    return false
  }
  func setEnabled(_ enabled: Bool) throws {
    loginCalls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> Value {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> [Value] {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> Bool {
    calls += 1
    return false
  }
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) throws -> Bool {
    calls += 1
    return false
  }
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    value: Value
  ) throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  @MainActor func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
}

private actor PresentationTransport: DeviceScriptRunning, BluetoothDeviceTransport,
  DDCDisplayTransport, ProfileHTTPTransport
{
  private(set) var calls = 0
  func run(script: String) async throws -> DeviceScriptResult {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func snapshot() async throws -> BluetoothTransportSnapshot {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func connect(id: String) async throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  @MainActor func observePowerChanges(_ onChange: @escaping @MainActor @Sendable () -> Void)
    -> DevicePropertyObservation
  {
    Issue.record("Projection must not register Bluetooth observers")
    return DevicePropertyObservation {}
  }
  func discover() async throws -> [DDCDisplaySnapshot] {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readVolume(displayID: UUID) async throws -> DDCVCPValue {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func close() async throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
}

@MainActor
private struct PresentationDisplayChanges: DisplayParameterObserving {
  func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    Issue.record("Projection must not register display observers")
    return DevicePropertyObservation {}
  }
}

private enum PresentationFailure: Error { case unexpectedIO }
