import AppKit
import AppTestSupport
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("Output policy to actual Root graph routing", .timeLimit(.minutes(1)))
@MainActor
struct OutputPolicyRoutingTests {
  @Test("A rejected lower Bluetooth auto-switch cannot retarget following apps when restore fails")
  func failedRestoreDoesNotRetargetFollowingApp() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneOutputPolicyRouting-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: PolicyRoutingLogin())
    settings.setDevicePriorityOrder(["high", "mid", "low"])
    settings.setDeviceRouting(for: "unit.pinned-high", deviceUID: "high")
    let devices = PolicyRoutingDevices()
    let processes = PolicyRoutingProcesses()
    let volumes = PolicyRoutingVolumes()
    let runtime = RoutingProbeRuntime()
    let http = PolicyRoutingHTTP()
    let clock = DevicePolicyTestClock()
    let policy = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { try volumes.restoreDefaultOutput($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache(),
        transport: http),
      devices: devices, processes: processes, volumes: volumes,
      runtime: CaptureUsageRuntime(runtime: runtime, usageDescription: "Unit capture admission"),
      readOutputFailure: { nil },
      readDefaultRoutingDecision: {
        policy.routingDecision()
      },
      deviceCommand: { _ in Issue.record("Routing ingestion must not write hardware") })

    // High was already present: Mid is the user's confirmed choice, not a new priority winner.
    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "mid", bluetoothUIDs: [])
    graph.engine.ingestObservations()
    graph.controller.perform(.requestCaptureStart)
    await graph.controller.waitForCurrentWork()
    let mid = try #require(runtime.handle("mid"))
    let high = try #require(runtime.handle("high"))
    #expect(mid.rendering && high.rendering && runtime.requests.count == 2)
    #expect(graph.controller.activeDeviceUIDs(for: "unit.follow-default") == ["mid"])
    #expect(graph.controller.activeDeviceUIDs(for: "unit.pinned-high") == ["high"])

    // Connect Low first, then report the OS auto-switch while the actual Bluetooth grace is active.
    devices.connectLow()
    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "mid", bluetoothUIDs: ["low"])
    graph.engine.ingestObservations()
    await graph.controller.waitForCurrentWork()
    #expect(policy.graceConnectionUID == "low" && policy.graceDuration == .seconds(5))
    #expect(volumes.restoreAttempts.isEmpty && runtime.requests.count == 2)

    volumes.defaultDeviceID = 43
    volumes.defaultDeviceUID = "low"
    // Same public-component order as Root's private default callback, then a process ingestion.
    // This is not a call into ProductionRoot, whose live OS adapters are deliberately not built.
    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
    graph.engine.refreshDeviceLevels()
    graph.engine.ingestObservations()
    await graph.controller.waitForCurrentWork()

    #expect(volumes.restoreAttempts == ["mid"])
    #expect(policy.lastFailure?.message == "Restore Mid failed")
    #expect(policy.intendedDefaultUID == "mid")
    #expect(policy.observedDefaultUID == "low" && volumes.defaultDeviceUID == "low")
    // Do not make observed OS truth look like a successful restore.
    #expect(volumes.defaultDeviceID == 43)
    #expect(runtime.requests.filter { $0.key.deviceUID == "low" }.isEmpty)
    #expect(graph.controller.activeDeviceUIDs(for: "unit.follow-default") == ["mid"])
    #expect(mid.rendering && !mid.retired)
    #expect(graph.controller.activeDeviceUIDs(for: "unit.pinned-high") == ["high"])
    #expect(high.rendering && !high.retired)
    #expect(settings.isFollowingDefault(for: "unit.follow-default"))
    #expect(settings.getDeviceRouting(for: "unit.pinned-high") == "high")
    #expect(settings.devicePriorityOrder == ["high", "mid", "low"])
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    let httpRequests = await http.requests
    #expect(httpRequests == 0)

    await graph.controller.shutdown()
    settings.flushSync()
    let restored = SettingsManager(directory: directory, launchAtLoginService: PolicyRoutingLogin())
    #expect(restored.isFollowingDefault(for: "unit.follow-default"))
    #expect(restored.getDeviceRouting(for: "unit.pinned-high") == "high")
    #expect(restored.appSettings.explicitUserCaptureEnabled)
  }

  @Test(
    "Explicit output settling repairs Bluetooth rebound without replacing following or pinned owners"
  )
  func manualBluetoothReboundKeepsApprovedFollowingOwner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneOutputPolicyRouting-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(directory: directory, launchAtLoginService: PolicyRoutingLogin())
    settings.setDevicePriorityOrder(["high", "mid", "low"])
    settings.setDeviceRouting(for: "unit.pinned-high", deviceUID: "high")
    let devices = PolicyRoutingDevices()
    devices.connectLow()  // Bluetooth is in the initial baseline, not a hotplug grace event.
    let processes = PolicyRoutingProcesses()
    let volumes = PolicyRoutingVolumes()
    volumes.defaultDeviceID = 43
    volumes.defaultDeviceUID = "low"
    volumes.restoreFailure = nil
    let runtime = RoutingProbeRuntime()
    let http = PolicyRoutingHTTP()
    let clock = DevicePolicyTestClock()
    let policy = OutputDevicePolicyController(
      settings: settings, setDefaultOutput: { try volumes.restoreDefaultOutput($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    let graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache(),
        transport: http),
      devices: devices, processes: processes, volumes: volumes,
      runtime: CaptureUsageRuntime(runtime: runtime, usageDescription: "Unit capture admission"),
      readOutputFailure: { nil }, readDefaultRoutingDecision: { policy.routingDecision() },
      deviceCommand: { command in
        if case .setDefaultDevice(.output, let uid) = command {
          try policy.selectDefaultOutput(uid: uid)
        } else {
          Issue.record("Unexpected device command in output-selection fixture")
        }
      })
    func observeDefault(_ uid: String, at instant: Double) {
      clock.now = instant
      volumes.defaultDeviceUID = uid
      volumes.defaultDeviceID = uid == "mid" ? 42 : 43
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: uid, bluetoothUIDs: ["low"])
      graph.engine.ingestObservations()
    }
    observeDefault("low", at: 0)
    graph.controller.perform(.requestCaptureStart)
    await graph.controller.waitForCurrentWork()
    let pinned = try #require(runtime.handle("high"))
    #expect(runtime.requests.count == 2 && policy.graceConnectionUID == nil)
    graph.controller.perform(.setDefaultDevice(scope: .output, uid: "mid"))
    await graph.controller.waitForCurrentWork()
    let following = try #require(runtime.handle("mid"))
    #expect(graph.controller.commandFailure == nil)
    #expect(volumes.restoreAttempts == ["mid"] && runtime.requests.count == 3)
    #expect(policy.observedDefaultUID == "low" && policy.intendedDefaultUID == "mid")
    observeDefault("mid", at: 0.05)
    await graph.controller.waitForCurrentWork()
    observeDefault("low", at: 0.3)
    await graph.controller.waitForCurrentWork()
    #expect(volumes.restoreAttempts == ["mid", "mid"])
    #expect(policy.observedDefaultUID == "low" && volumes.defaultDeviceUID == "low")
    #expect(policy.intendedDefaultUID == "mid" && policy.lastFailure == nil)
    #expect(policy.graceConnectionUID == nil)
    #expect(graph.controller.activeDeviceUIDs(for: "unit.follow-default") == ["mid"])
    #expect(following.rendering && !following.retired && runtime.requests.count == 3)
    #expect(graph.controller.activeDeviceUIDs(for: "unit.pinned-high") == ["high"])
    #expect(pinned.rendering && pinned.retirementAttempts == 0)
    observeDefault("mid", at: 0.35)
    await graph.controller.waitForCurrentWork()
    #expect(policy.observedDefaultUID == "mid" && policy.intendedDefaultUID == "mid")
    #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
    #expect(
      following.rendering && runtime.handle("mid") === following && runtime.requests.count == 3)
    observeDefault("low", at: 2.001)
    await graph.controller.waitForCurrentWork()
    #expect(volumes.restoreAttempts == ["mid", "mid"])
    #expect(policy.intendedDefaultUID == "low" && policy.observedDefaultUID == "low")
    #expect(graph.controller.activeDeviceUIDs(for: "unit.follow-default") == ["low"])
    #expect(runtime.requests.count == 4)
    #expect(runtime.handle("high") === pinned && pinned.rendering && pinned.retirementAttempts == 0)
    #expect(settings.isFollowingDefault(for: "unit.follow-default"))
    #expect(settings.getDeviceRouting(for: "unit.pinned-high") == "high")
    #expect(await http.requests == 0)
    await graph.controller.shutdown()
  }
}

@MainActor
private final class PolicyRoutingDevices: AudioDeviceObservationProviding {
  var observation = AudioDeviceObservationSnapshot(
    outputDevices: [
      AudioDevice(
        id: 41, uid: "high", name: "High", icon: nil, supportsAutoEQ: false, bindingRevision: 1),
      AudioDevice(
        id: 42, uid: "mid", name: "Mid", icon: nil, supportsAutoEQ: false, bindingRevision: 1),
    ], health: .healthy, revision: 1)
  var outputDevices: [AudioDevice] { observation.outputDevices }
  var inputDevices: [AudioDevice] { [] }
  var onObservationChanged: (() -> Void)?
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  func connectLow() {
    observation = AudioDeviceObservationSnapshot(
      outputDevices: outputDevices + [
        AudioDevice(
          id: 43, uid: "low", name: "Low Bluetooth", icon: nil, supportsAutoEQ: false,
          bindingRevision: 1, transportType: .bluetooth)
      ], health: .healthy, revision: 2)
  }
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { nil }
  func start() { Issue.record("The fixture must not start OS observation") }
  func stop() { Issue.record("The fixture does not own OS observation") }
}

@MainActor
private final class PolicyRoutingProcesses: AudioProcessObservationProviding {
  let observation = AudioProcessObservationSnapshot(
    activeApps: [
      AudioApp(
        id: 101, processObjectIDs: [701], name: "Following player",
        icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: "unit.follow-default",
        processRevision: 1),
      AudioApp(
        id: 102, processObjectIDs: [702], name: "Pinned player",
        icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: "unit.pinned-high",
        processRevision: 1),
    ], health: .healthy, revision: 1)
  var activeApps: [AudioApp] { observation.activeApps }
  var onObservationChanged: (() -> Void)?
  var onAppsChanged: (([AudioApp]) -> Void)?
  func start() { Issue.record("The fixture must not start process observation") }
  func stop() { Issue.record("The fixture does not own process observation") }
}

@MainActor
private final class PolicyRoutingVolumes: DeviceVolumeProviding {
  var defaultDeviceID: AudioDeviceID = 42
  var defaultDeviceUID: String? = "mid"
  let defaultInputDeviceUID: String? = nil
  let volumes: [AudioDeviceID: Float] = [41: 0.5, 42: 0.5, 43: 0.5]
  let muteStates: [AudioDeviceID: Bool] = [41: false, 42: false, 43: false]
  var restoreAttempts: [String] = []
  var restoreFailure: AudioRouteFailure? = AudioRouteFailure(
    stage: "output-write", message: "Restore Mid failed")
  var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
  var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
  var onDefaultDeviceChanged: ((String) -> Void)?
  var onDefaultInputDeviceChanged: ((String) -> Void)?
  func restoreDefaultOutput(_ uid: String) throws {
    restoreAttempts.append(uid)
    if let restoreFailure { throw restoreFailure }
  }
  func setDefaultDevice(_ id: AudioDeviceID) -> Bool {
    Issue.record("Unexpected physical default write")
    return false
  }
  func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
    Issue.record("Unexpected physical input write")
    return false
  }
  func setVolume(for id: AudioDeviceID, to value: Float) {
    Issue.record("Unexpected physical volume write")
  }
  func setMute(for id: AudioDeviceID, to value: Bool) { Issue.record("Unexpected mute write") }
  func outputVolumeBackend(for id: AudioDeviceID) -> VolumeControlTier { .hardware }
  func start() { Issue.record("The fixture must not start OS volume services") }
  func stop() { Issue.record("The fixture does not own OS volume services") }
}

private actor PolicyRoutingHTTP: ProfileHTTPTransport {
  private(set) var requests = 0
  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    requests += 1
    throw AudioRouteFailure(stage: "unit-http", message: "Output policy must not request HTTP")
  }
}

@MainActor
private final class PolicyRoutingLogin: LaunchAtLoginService {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws { Issue.record("Unexpected login mutation") }
}
