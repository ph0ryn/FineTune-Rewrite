import AppKit
import AppTestSupport
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import Foundation
import Observation
import Testing

@testable import FineTune
@testable import FineTuneControl
@testable import FineTunePlatform

@Suite("App composition: RootPresentation read-through and projection wiring")
@MainActor
struct RootPresentationWiringTests {
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

  @Test("Settings snapshots ignore peak-only route updates")
  func settingsSnapshotsIgnorePeakLevels() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let controller = fixture.graph.controller
    let key = AudioRouteKey(appIdentifier: "unit.player", deviceUID: "speaker", generation: 1)
    controller.routeObservations[key] = AudioRouteObservation(
      key: key, phase: .firstApplied, peakLevel: 0.25)

    let count = await invalidationCount(
      read: { _ = presentation.settingsSnapshot() },
      mutate: {
        controller.routeObservations[key] = AudioRouteObservation(
          key: key, phase: .firstApplied, peakLevel: 0.75)
      })
    #expect(count == 0)
  }

  @Test("Mixer snapshots still observe peak-only route updates")
  func mixerSnapshotsObservePeakLevels() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let controller = fixture.graph.controller
    let key = AudioRouteKey(appIdentifier: "unit.player", deviceUID: "speaker", generation: 1)
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    controller.routeObservations[key] = AudioRouteObservation(
      key: key, phase: .firstApplied, peakLevel: 0.25)

    let count = await invalidationCount(
      read: { _ = presentation.mixerSnapshot().apps.first?.peakLevel },
      mutate: {
        controller.routeObservations[key] = AudioRouteObservation(
          key: key, phase: .firstApplied, peakLevel: 0.75)
      })
    #expect(count == 1)
  }

  @Test("Route diagnostic changes still invalidate settings snapshots")
  func settingsSnapshotsObserveRouteDiagnostics() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let controller = fixture.graph.controller
    let key = AudioRouteKey(appIdentifier: "unit.player", deviceUID: "speaker", generation: 1)
    controller.routeObservations[key] = AudioRouteObservation(
      key: key, phase: .firstApplied, peakLevel: 0.25)

    let count = await invalidationCount(
      read: { _ = presentation.settingsSnapshot() },
      mutate: {
        controller.routeObservations[key] = AudioRouteObservation(
          key: key, phase: .failed,
          failure: AudioRouteFailure(kind: .nativeFailure, stage: "test", message: "Route failed"))
      })
    #expect(count == 1)
  }

  private func invalidationCount(
    read: () -> Void, mutate: () -> Void
  ) async -> Int {
    let invalidations = AsyncStream<Void>.makeStream()
    withObservationTracking {
      read()
    } onChange: {
      invalidations.continuation.yield(())
    }
    mutate()
    invalidations.continuation.finish()
    var count = 0
    for await _ in invalidations.stream { count += 1 }
    return count
  }

  @Test("Output selection failure callback invalidates both snapshots without mutating route state")
  func outputSelectionFailureIsVisible() async throws {
    var selectionFailure: String?
    let fixture = try RootPresentationFixture(readOutputSelectionFailure: { selectionFailure })
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    #expect(presentation.mixerSnapshot().error == nil)
    #expect(presentation.settingsSnapshot().error == nil)

    let invalidations = AsyncStream<Void>.makeStream()
    withObservationTracking {
      _ = presentation.mixerSnapshot().error
      _ = presentation.settingsSnapshot().error
    } onChange: {
      invalidations.continuation.yield(())
    }
    selectionFailure = "Unable to keep the selected output."
    presentation.invalidate()
    invalidations.continuation.finish()
    var count = 0
    for await _ in invalidations.stream { count += 1 }
    #expect(count == 1)
    #expect(presentation.mixerSnapshot().error == selectionFailure)
    #expect(presentation.settingsSnapshot().error == selectionFailure)

    selectionFailure = nil
    presentation.invalidate()
    #expect(presentation.mixerSnapshot().error == nil)
    #expect(presentation.settingsSnapshot().error == nil)
    await fixture.expectPassivePorts()
  }

  @Test("Snapshots read live plus saved app identities, user presets, and flags without copies")
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
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.perform(.setPinned(identifier: "unit.live-a", pinned: true))
    controller.perform(.setPinned(identifier: "unit.saved", pinned: true))
    controller.perform(.setIgnored(identifier: "unit.live-b", ignored: true))
    controller.perform(.setIgnored(identifier: "unit.ignored", ignored: true))
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
    #expect(snapshot.userPresets.map(\.id) == [preset.id])
    let settings = presentation.settingsSnapshot()
    #expect(settings.settings.explicitUserCaptureEnabled)
    #expect(settings.isAccessibilityTrusted && settings.isMediaKeyOffline)
    #expect(controller.captureIntent == .none)
    #expect(snapshot.captureNotice?.action == .requestPermission)
    await fixture.expectPassivePorts(halBaseline: halBeforeSnapshot)
  }

  @Test("Inactive saved rows retain cached installed artwork without reading OS metadata")
  func savedRowsUseCachedArtwork() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let savedIcon = NSImage(size: NSSize(width: 2, height: 2))
    let ignoredIcon = NSImage(size: NSSize(width: 3, height: 3))
    fixture.inactiveIcons = ["unit.saved": savedIcon, "unit.ignored": ignoredIcon]
    fixture.processes.apps = [
      fixture.app(id: 101, uid: "unit.saved", name: "Saved"),
      fixture.app(id: 102, uid: "unit.ignored", name: "Ignored"),
      fixture.app(id: 103, uid: "unit.missing", name: "Missing"),
    ]
    fixture.graph.engine.ingestObservations()
    fixture.graph.controller.perform(.setPinned(identifier: "unit.saved", pinned: true))
    fixture.graph.controller.perform(.setIgnored(identifier: "unit.ignored", ignored: true))
    fixture.graph.controller.perform(.setPinned(identifier: "unit.missing", pinned: true))
    fixture.processes.apps = []
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()

    let halBaseline = fixture.hal.calls
    let presentation = fixture.presentation()
    let rows = presentation.mixerSnapshot().apps
    #expect(rows.count == 3 && rows.allSatisfy { !$0.isActive && $0.peakLevel == nil })
    #expect(rows.first { $0.id == "unit.saved" }?.icon === savedIcon)
    #expect(rows.first { $0.id == "unit.ignored" }?.icon === ignoredIcon)
    #expect(rows.first { $0.id == "unit.missing" }?.icon == nil)
    presentation.applicationActivationFailure = "Unit reopen failed"
    #expect(presentation.mixerSnapshot().error == "Unit reopen failed")
    #expect(presentation.settingsSnapshot().error == "Unit reopen failed")
    presentation.applicationActivationFailure = nil
    #expect(presentation.mixerSnapshot().error == nil)
    await fixture.expectPassivePorts(halBaseline: halBaseline)
  }

  @Test("Mixer projects maximum healthy peak across multi routes and clears on fault or stop")
  func peakLevelProjection() async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      ["speaker", "headphones"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
          isMuted: false)
      }, defaultUID: "speaker")
    controller.perform(
      .setRoute(identifier: "unit.player", mode: .multi, uids: ["speaker", "headphones"]))
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()

    let speaker = try #require(runtime.handle("speaker"))
    let headphones = try #require(runtime.handle("headphones"))
    let presentation = fixture.presentation()
    speaker.onObservation?(
      AudioRouteObservation(key: speaker.key, phase: .firstApplied, peakLevel: 0.25))
    headphones.onObservation?(
      AudioRouteObservation(key: headphones.key, phase: .firstApplied, peakLevel: 0.75))
    let halBaseline = fixture.hal.calls
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0.75)

    headphones.onObservation?(
      AudioRouteObservation(key: headphones.key, phase: .firstApplied, peakLevel: nil))
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0.25)

    controller.observeApplications([], failure: "Process observation unavailable")
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    await controller.shutdown()
    await fixture.expectPassivePorts(halBaseline: halBaseline)
  }

  @Test(
    "Native diagnostics format stage, optional code, cleanup role, and fallback message",
    arguments: [Int32?(560_947_818), nil],
    [AudioRouteFailureKind.nativeFailure, .cancelled])
  func routeStatusFormatting(code: Int32?, kind: AudioRouteFailureKind) async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
          isMuted: false)
      ], defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("speaker"))

    let failure = AudioRouteFailure(
      kind: kind, stage: "createAggregate", code: code,
      message: "Native audio could not complete the requested operation.")
    route.onObservation?(
      AudioRouteObservation(
        key: route.key, phase: .failed, failure: failure, cleanupFailure: failure))
    let expectedPrimary =
      code.map { "\(failure.message) (stage: createAggregate, native code: \($0))" }
      ?? "\(failure.message) (stage: createAggregate)"
    let expectedCleanup =
      code.map { "\(failure.message) (cleanup stage: createAggregate, native code: \($0))" }
      ?? "\(failure.message) (cleanup stage: createAggregate)"
    let expected = "\(expectedPrimary)\n\(expectedCleanup)"

    let presentation = fixture.presentation()
    let snapshot = presentation.mixerSnapshot()
    #expect(snapshot.error == nil && snapshot.captureNotice == nil)
    #expect(snapshot.apps.first?.routeStatus == expected)
    #expect(presentation.settingsSnapshot().error == expected)
    if code == nil { #expect(!expected.contains("native code")) }
    await controller.shutdown()
  }

  @Test("Failed route without details shows fallback warning; stopped retired fault is hidden")
  func fallbackAndStoppedRouteProjection() async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
          isMuted: false)
      ], defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("speaker"))
    route.onObservation?(AudioRouteObservation(key: route.key, phase: .failed))

    let presentation = fixture.presentation()
    #expect(presentation.mixerSnapshot().apps.first?.routeStatus == "Audio routing failed.")

    controller.perform(.stopCapture)
    await controller.shutdown()
    let stopped = presentation.mixerSnapshot()
    #expect(stopped.captureNotice?.action == .requestPermission)
    #expect(stopped.error == nil && stopped.apps.first?.routeStatus == nil)
    #expect(presentation.settingsSnapshot().error == nil)
  }

  @Test(
    "Native cleanup warnings follow matching release, not the latest diagnostic or other recovery")
  func nativeCleanupWarningsFollowUnresolvedOwners() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let first = AudioRouteKey(appIdentifier: "first.app", deviceUID: "speaker", generation: 1)
    let second = AudioRouteKey(appIdentifier: "second.app", deviceUID: "speaker", generation: 2)
    let firstFailure = AudioRouteFailure(stage: "stop", code: 11, message: "First cleanup failed")
    let secondFailure = AudioRouteFailure(
      stage: "destroyTap", code: 22, message: "Second cleanup failed")
    fixture.native.recordCleanup(first, failure: firstFailure)
    fixture.native.recordCleanup(second, failure: secondFailure)

    let presentation = fixture.presentation()
    let snapshot = presentation.mixerSnapshot()
    #expect(snapshot.error?.contains(firstFailure.message) == true)
    #expect(snapshot.error?.contains(secondFailure.message) == true)
    #expect(presentation.settingsSnapshot().error == snapshot.error)

    fixture.native.recordRetired(second)
    let remaining = "First cleanup failed (cleanup stage: stop, native code: 11)"
    #expect(presentation.mixerSnapshot().error == remaining)
    #expect(presentation.settingsSnapshot().error == remaining)

    fixture.native.recordRetired(first)
    #expect(presentation.mixerSnapshot().error == nil)
    #expect(presentation.settingsSnapshot().error == nil)
    await fixture.expectPassivePorts()
  }

  @Test("The required activation action forwards exact identity without editing audio")
  func activationUsesTheRequiredPort() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    var activated: [String] = []
    let actions = fixture.graph.bindings.appActions(activate: { activated.append($0) })
    actions.activate("Com.Example.Player")
    #expect(activated == ["Com.Example.Player"])
    #expect(fixture.graph.controller.captureIntent == .none)
    #expect(fixture.graph.controller.applications.isEmpty)
    await fixture.expectPassivePorts()
  }

  @Test("Mixer presents shared process diagnostic once and retains independent errors")
  func processDiagnosticAppearsOnce() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let processFailure = "Application metadata has an invalid or duplicate process identity."
    fixture.graph.controller.observeApplications([], failure: processFailure)
    let processOnly = presentation.mixerSnapshot()
    #expect(processOnly.captureNotice?.message == processFailure)
    #expect(processOnly.error == nil)
    #expect(presentation.settingsSnapshot().error == processFailure)

    let outputFailure = "Output role observation is unavailable."
    fixture.graph.controller.observeOutputs([], defaultUID: nil, failure: outputFailure)
    let independent = presentation.mixerSnapshot()
    #expect(independent.captureNotice?.message == processFailure)
    #expect(independent.error == outputFailure)
    #expect(presentation.settingsSnapshot().error == "\(processFailure)\n\(outputFailure)")

    let missingUsageDescription = fixture.presentation(hasUsageDescription: false).mixerSnapshot()
    #expect(missingUsageDescription.captureNotice?.message != processFailure)
    #expect(missingUsageDescription.error == "\(processFailure)\n\(outputFailure)")
    await fixture.expectPassivePorts()
  }

  @Test("Eight device actions use the same Common port and failure notices retain their reasons")
  func deviceActionsAndFailureProjection() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let actions = presentation.deviceActions
    actions.setDefault(.input, "mic")
    actions.setVolume(.output, "speaker", 0.25)
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
    #expect(presentation.mixerSnapshot().error == nil)
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
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 0.5,
          isMuted: false)
      ], defaultUID: "speaker")
    fixture.graph.controller.perform(.requestCaptureStart)
    await fixture.graph.controller.waitForCurrentWork()
    #expect(
      fixture.effects.nativeResolutions == 1 && fixture.graph.controller.knownPermissionDenied)
    let denied = presentation.mixerSnapshot()
    #expect(denied.captureNotice?.action == .openSettings)
    #expect(denied.error == nil && denied.apps.first?.routeStatus == nil)

    fixture.graph.controller.perform(.stopCapture)
    await fixture.graph.controller.shutdown()
    let stopped = presentation.mixerSnapshot()
    #expect(stopped.captureNotice?.action == .requestPermission)
    #expect(stopped.error == nil)
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
  var inactiveIcons: [String: NSImage] = [:]

  init(
    runtime: (any AudioRoutingRuntime)? = nil,
    captureFailure: AudioRouteFailure = AudioRouteFailure(
      kind: .permissionDenied, stage: "unit-native-preflight",
      message: "Unit capture denied before native I/O"),
    readOutputSelectionFailure: @escaping @MainActor () -> String? = { nil }
  ) throws {
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
      outputPreferencesDidChange: { Issue.record("Projection must not run output policy") },
      readOutputSelectionFailure: readOutputSelectionFailure)
    let effects = effects
    native = NativeAudioRoutingRuntime { _, _ in
      effects.nativeResolutions += 1
      throw captureFailure
    }
    graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache(),
        transport: transport),
      devices: devices, processes: processes, volumes: output, runtime: runtime ?? native,
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
      hasCaptureUsageDescription: hasUsageDescription,
      applicationIcon: { [unowned self] bundleID in bundleID.flatMap { inactiveIcons[$0] } })
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
      id: 10, uid: "speaker", name: "Speaker", icon: nil, supportsAutoEQ: false, bindingRevision: 1)
  ]
  let inputDevices = [
    AudioDevice(
      id: 20, uid: "mic", name: "Microphone", icon: nil, supportsAutoEQ: false, bindingRevision: 1)
  ]
  var starts = 0
  var onObservationChanged: (() -> Void)?
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  var observation: AudioDeviceObservationSnapshot {
    AudioDeviceObservationSnapshot(
      outputDevices: outputDevices, inputDevices: inputDevices, health: .healthy, revision: 1)
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
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    calls += 1
    return false
  }
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
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
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    onChange: @escaping @MainActor @Sendable () -> Void
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
