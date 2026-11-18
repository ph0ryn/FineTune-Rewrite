import AppKit
import AppTestSupport
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("App composition: ProductionRoot and ApplicationGraph wiring", .timeLimit(.minutes(1)))
@MainActor
struct RootWiringTests {
  @Test(
    "Root input suspension unregisters held global shortcuts; only a fresh registration resumes input",
    arguments: [LifecycleEvent.sessionResigned, .systemWillSleep])
  func inputBridgeStopsHeldShortcuts(_ event: LifecycleEvent) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootInput-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: RootWiringLogin())
    let volumes = RootWiringVolumes()
    let runtime = RoutingProbeRuntime()
    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache()),
      devices: RootWiringDevices(), processes: RootWiringProcesses(), volumes: volumes,
      runtime: runtime, readOutputFailure: { volumes.failure },
      readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { _ in Issue.record("Shortcut app gain must not write a device") })
    graph.engine.ingestObservations()
    let keyboard = RootInputKeyboard()
    let hud = RootInputHUD()
    let registry = ShortcutsRegistry(
      settings: settings, popupController: RootInputPopup(),
      resolver: TargetAppResolver(
        ownBundleID: "unit.root", frontmostBundleIDProvider: { "unit.player" }),
      audioEngine: graph.engine, hud: hud, keyboard: keyboard)
    var mediaKeysActive = false
    let lifecycle = LifecycleCoordinator(
      settings: settings,
      ports: LifecyclePorts(
        start: {
          registry.start()
          mediaKeysActive = true
        },
        shutdown: {
          registry.stop()
          await graph.controller.shutdown()
        },
        suspendAudio: { await graph.controller.shutdown() },
        resumeAudio: { graph.controller.resume() },
        suspendInput: {
          ProductionRoot.suspendInput(
            shortcuts: registry, stopMediaKeys: { mediaKeysActive = false })
        },
        resumeInput: {
          ProductionRoot.resumeInput(
            shortcuts: registry, refreshMediaKeys: { mediaKeysActive = true })
        }))
    await lifecycle.start()
    let identifier = ShortcutAction.targetAppVolumeDown.stableID
    let heldDown = try #require(keyboard.keyDown[identifier])
    heldDown()
    #expect(hud.volumeCalls == 1)
    #expect(graph.controller.gain(for: "unit.player") < 1)

    await lifecycle.handle(event)
    #expect(!mediaKeysActive)
    #expect(keyboard.keyDown.isEmpty)
    let suspendedGain = graph.controller.gain(for: "unit.player")
    let suspendedHUDCount = hud.volumeCalls
    heldDown()
    #expect(graph.controller.gain(for: "unit.player") == suspendedGain)
    #expect(hud.volumeCalls == suspendedHUDCount)

    switch event {
    case .sessionResigned: await lifecycle.handle(.sessionBecameActive)
    case .systemWillSleep: await lifecycle.handle(.systemDidWake)
    default: Issue.record("The finite table contains only input-suspending events")
    }
    #expect(mediaKeysActive)
    #expect(keyboard.registrations == ShortcutAction.allCases.count * 2)
    let beforeFreshKey = graph.controller.gain(for: "unit.player")
    let freshDown = try #require(keyboard.keyDown[identifier])
    freshDown()
    #expect(graph.controller.gain(for: "unit.player") < beforeFreshKey)
    #expect(runtime.requests.isEmpty)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
    await lifecycle.stop()
  }

  @Test(
    "Policy payload does not turn not-started discovery into healthy empty data or hide role errors"
  )
  func discoveryAndRoleFailuresRemainExplicit() throws {
    #expect(
      ProductionRoot.devicePolicyFailure(health: .notStarted, defaultReadFailure: nil) != nil)
    #expect(ProductionRoot.devicePolicyFailure(health: .healthy, defaultReadFailure: nil) == nil)
    let both = try #require(
      ProductionRoot.devicePolicyFailure(
        health: .failed("Discovery failed"), defaultReadFailure: "Default role read failed"))
    #expect(both.contains("Discovery failed"))
    #expect(both.contains("Default role read failed"))
  }

  @Test(
    "Cooperative stop reports owned cleanup debt but accepts a later retired ACK without erasing history"
  )
  func stopAfterRetiredCleanupRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootCleanup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: RootWiringLogin())
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "A", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1,
          volume: 0.5, isMuted: false)
      ], defaultUID: "A")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: "unit.player", processID: 101, processRevision: 1,
        displayName: "Player", bundleID: "unit.player")
    ])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))
    #expect(route.rendering)

    let cleanup = AudioRouteFailure(
      stage: "root-retire", message: "Retirement pending cleanup failure")
    runtime.holdRetirement = ["A"]
    runtime.retirementCallbackFailure = cleanup
    runtime.retirementCallbackUsesCleanup = true
    let lifecycle = LifecycleCoordinator(
      settings: settings,
      ports: LifecyclePorts(
        start: { controller.resume() },
        shutdown: {
          await controller.shutdown()
          try ProductionRoot.checkControllerCleanup(controller)
        },
        suspendAudio: { await controller.shutdown() },
        resumeAudio: { controller.resume() }, suspendInput: {}, resumeInput: {}))
    await lifecycle.start()
    await lifecycle.stop()
    #expect(lifecycle.phase == .failed)
    #expect(!route.retired)
    #expect(controller.routeObservations[route.key]?.cleanupFailure == cleanup)
    #expect(lifecycle.lastError?.contains(cleanup.message) == true)

    route.finishRetirement()
    #expect(controller.routeObservations[route.key]?.phase == .retired)
    #expect(controller.routeObservations[route.key]?.cleanupFailure == cleanup)
    await lifecycle.stop()
    #expect(lifecycle.phase == .stopped)
    #expect(controller.routeObservations[route.key]?.cleanupFailure == cleanup)
  }

  @Test("Wake publishes current failure before resuming a cached input lock or native admission")
  func wakeFeedsCurrentHealthBeforeResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootWake-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: RootWiringLogin())
    var appSettings = settings.appSettings
    appSettings.lockInputDevice = true
    settings.updateAppSettings(appSettings)
    settings.setPreferredInputDeviceUID("inputA")
    settings.setLockedInputDeviceUID("inputA")
    let volumes = RootWiringVolumes()
    let runtime = RoutingProbeRuntime()
    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache()),
      devices: RootWiringDevices(), processes: RootWiringProcesses(), volumes: volumes,
      runtime: runtime, readOutputFailure: { volumes.failure },
      readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { _ in Issue.record("Read-only wake must not issue a UI device command") })
    var inputWrites: [String] = []
    let input = InputDevicePolicyController(
      settings: settings, setDefaultInput: { inputWrites.append($0) })
    let output = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { _ in Issue.record("Unexpected output default write") }
    )
    defer {
      input.suspend()
      output.suspend()
    }
    input.observe(
      availableUIDs: ["inputA", "inputB"], defaultUID: "inputB",
      builtInUIDs: ["inputA"], bluetoothUIDs: [])
    #expect(inputWrites == ["inputA"])
    graph.engine.ingestObservations()
    graph.controller.perform(.requestCaptureStart)
    await graph.controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)

    input.suspend()
    output.suspend()
    await graph.controller.shutdown()
    inputWrites.removeAll()
    volumes.failure = "Current default-role reads are unavailable after sleep"

    ProductionRoot.resumeAudio(
      graph: graph, inputPolicy: input, outputPolicy: output,
      observeCurrentPolicies: {
        input.observe(
          availableUIDs: ["inputA", "inputB"], defaultUID: "inputB",
          builtInUIDs: ["inputA"], bluetoothUIDs: [], failure: volumes.failure)
      })
    await graph.controller.waitForCurrentWork()
    #expect(inputWrites.isEmpty)
    #expect(runtime.requests.count == 1)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.preferredInputDeviceUID == "inputA")

    volumes.failure = nil
    input.observe(
      availableUIDs: ["inputA", "inputB"], defaultUID: "inputA",
      builtInUIDs: ["inputA"], bluetoothUIDs: [])
    graph.engine.refreshDeviceLevels()
    await graph.controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(runtime.handle("A")?.rendering == true)
    await graph.controller.shutdown()
  }

  @Test("An unreadable last-good default cannot resume through AudioEngine process ingestion")
  func defaultFailureSurvivesProcessIngestion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootHealth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: RootWiringLogin())
    let devices = RootWiringDevices()
    let processes = RootWiringProcesses()
    let volumes = RootWiringVolumes()
    let runtime = RoutingProbeRuntime()
    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache()),
      devices: devices, processes: processes, volumes: volumes, runtime: runtime,
      readOutputFailure: { volumes.failure },
      readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { _ in Issue.record("Read-only ingestion must not write a device") })
    graph.engine.ingestObservations()
    graph.controller.perform(.requestCaptureStart)
    await graph.controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    let first = try #require(runtime.handle("A"))
    #expect(first.commits.count == 1)

    volumes.failure = "Default output read failed"
    graph.engine.refreshDeviceLevels()
    #expect(!first.cancelled)
    processes.publish(revision: 2)
    graph.engine.ingestObservations()
    await graph.controller.waitForCurrentWork()
    #expect(runtime.requests.count == 1)
    #expect(!first.retired)

    volumes.failure = nil
    processes.publish(revision: 3)
    graph.engine.ingestObservations()
    await graph.controller.waitForCurrentWork()
    #expect(runtime.requests.count == 2)
    #expect(runtime.requests.last?.processRevision == 3)
    #expect(first.retired)
    await graph.controller.shutdown()
  }

  @Test(
    "ApplicationGraph wires readDefaultRoutingDecision and setDefaultDevice through OutputPolicy")
  func applicationGraphWiresOutputPolicyClosures() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootPolicyWire-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: RootWiringLogin())
    let devices = RootWiringDevices(extraUID: "B")
    let processes = RootWiringProcesses()
    let volumes = RootWiringVolumes()
    let runtime = RoutingProbeRuntime()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { writes.append($0) })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: [])

    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache()),
      devices: devices, processes: processes, volumes: volumes, runtime: runtime,
      readOutputFailure: { volumes.failure },
      readDefaultRoutingDecision: { policy.routingDecision() },
      deviceCommand: { command in
        if case .setDefaultDevice(.output, let uid) = command {
          try policy.selectDefaultOutput(uid: uid)
        }
      })
    graph.engine.ingestObservations()
    graph.controller.perform(.requestCaptureStart)
    await graph.controller.waitForCurrentWork()
    #expect(graph.controller.activeDeviceUIDs(for: "unit.player") == ["A"])

    graph.controller.perform(.setDefaultDevice(scope: .output, uid: "B"))
    await graph.controller.waitForCurrentWork()
    #expect(writes == ["B"])
    #expect(policy.intendedDefaultUID == "B")
    #expect(graph.controller.activeDeviceUIDs(for: "unit.player") == ["B"])
    await graph.controller.shutdown()
  }
}

@MainActor
private final class RootWiringDevices: AudioDeviceObservationProviding {
  let observation: AudioDeviceObservationSnapshot
  init(extraUID: String? = nil) {
    var outputs = [
      AudioDevice(
        id: 42, uid: "A", name: "Output", icon: nil, supportsAutoEQ: false, bindingRevision: 1)
    ]
    if let extraUID {
      outputs.append(
        AudioDevice(
          id: 43, uid: extraUID, name: "Extra", icon: nil, supportsAutoEQ: false,
          bindingRevision: 1))
    }
    observation = AudioDeviceObservationSnapshot(
      outputDevices: outputs, health: .healthy, revision: 1)
  }
  var outputDevices: [AudioDevice] { observation.outputDevices }
  var inputDevices: [AudioDevice] { observation.inputDevices }
  var onObservationChanged: (() -> Void)?
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { nil }
  func start() { Issue.record("Root must own observer startup") }
  func stop() { Issue.record("Root must own observer shutdown") }
}

@MainActor
private final class RootWiringProcesses: AudioProcessObservationProviding {
  var observation: AudioProcessObservationSnapshot
  var activeApps: [AudioApp] { observation.activeApps }
  var onObservationChanged: (() -> Void)?
  var onAppsChanged: (([AudioApp]) -> Void)?
  init() { observation = Self.snapshot(revision: 1) }
  func publish(revision: UInt64) { observation = Self.snapshot(revision: revision) }
  private static func snapshot(revision: UInt64) -> AudioProcessObservationSnapshot {
    AudioProcessObservationSnapshot(
      activeApps: [
        AudioApp(
          id: 101, processObjectIDs: [701], name: "Player",
          icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: "unit.player",
          processRevision: revision)
      ],
      health: .healthy, revision: revision)
  }
  func start() { Issue.record("Root must own observer startup") }
  func stop() { Issue.record("Root must own observer shutdown") }
}

@MainActor
private final class RootWiringVolumes: DeviceVolumeProviding {
  var failure: String?
  let defaultDeviceID: AudioDeviceID = 42
  let defaultDeviceUID: String? = "A"
  let defaultInputDeviceUID: String? = nil
  let volumes: [AudioDeviceID: Float] = [42: 0.5, 43: 0.5]
  let muteStates: [AudioDeviceID: Bool] = [42: false, 43: false]
  var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
  var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
  var onDefaultDeviceChanged: ((String) -> Void)?
  var onDefaultInputDeviceChanged: ((String) -> Void)?
  func setDefaultDevice(_ id: AudioDeviceID) -> Bool {
    Issue.record("Unexpected hardware write")
    return false
  }
  func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
    Issue.record("Unexpected hardware write")
    return false
  }
  func setVolume(for id: AudioDeviceID, to value: Float) {
    Issue.record("Unexpected hardware write")
  }
  func setMute(for id: AudioDeviceID, to value: Bool) { Issue.record("Unexpected hardware write") }
  func outputVolumeBackend(for id: AudioDeviceID) -> VolumeControlTier { .hardware }
  func start() { Issue.record("Root must own volume startup") }
  func stop() { Issue.record("Root must own volume shutdown") }
}

@MainActor
private final class RootInputKeyboard: ShortcutRegistering {
  var keyDown: [String: @MainActor () -> Void] = [:]
  var registrations = 0
  func shortcut(for identifier: String) -> ShortcutCodable? { nil }
  func setShortcut(_ shortcut: ShortcutCodable?, for identifier: String) {
    Issue.record("The fresh input fixture has no saved shortcut to rewrite")
  }
  func register(
    identifier: String, onKeyDown: @escaping @MainActor () -> Void,
    onKeyUp: @escaping @MainActor () -> Void
  ) {
    registrations += 1
    keyDown[identifier] = onKeyDown
  }
  func unregister(identifier: String) { keyDown[identifier] = nil }
}

@MainActor
private final class RootInputPopup: MenuBarPopupControlling {
  func toggle() { Issue.record("Volume shortcuts must not open the popup") }
}

@MainActor
private final class RootInputHUD: PerAppHUDPresenting {
  var volumeCalls = 0
  func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) { volumeCalls += 1 }
  func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
    Issue.record("The finite input trace changes gain only")
  }
  func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
    Issue.record("The actual cached process is a controllable target")
  }
}

@MainActor
private final class RootWiringLogin: LaunchAtLoginService {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws { Issue.record("Unexpected login mutation") }
}
