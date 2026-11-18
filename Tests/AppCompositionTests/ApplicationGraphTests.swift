import AppTestSupport
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite(
  "App composition: ApplicationGraph and RootBindings wiring", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ApplicationGraphTests {
  @Test("Cold graph shares one store, cache, controller, and observer set without starting OS I/O")
  func oneActualGraphWithoutStartingOSServices() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootGraph-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: GraphTestLoginService())
    let cache = AutoEQProfileCache()
    let repository = try AutoEQProfileRepository(
      directory: directory.appendingPathComponent("Profiles"), cache: cache)
    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    let volumes = CoreAudioDeviceVolumeAdapter(deviceProvider: devices, settingsManager: settings)
    let runtime = RoutingProbeRuntime()
    let graph = ApplicationGraph(
      settings: settings, profiles: repository, devices: devices, processes: processes,
      volumes: volumes, runtime: runtime, readOutputFailure: { volumes.defaultOutputReadFailure },
      readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { _ in
        Issue.record("Constructing and editing inactive app wishes must not write hardware.")
        throw AudioRouteFailure(
          kind: .unavailable, stage: "unit-device", message: "Unexpected write")
      })

    #expect(graph.settings === settings)
    #expect(graph.profiles === repository)
    #expect(graph.profiles.cache === cache)
    #expect(graph.controller === graph.engine.controller)
    #expect(graph.bindings.controller === graph.controller)
    #expect(graph.engine.settingsManager === settings)
    #expect(graph.engine.deviceVolumeMonitor === volumes)
    #expect(graph.devices === devices && graph.processes === processes)
    #expect(devices.onObservationChanged == nil && processes.onObservationChanged == nil)
    #expect(devices.observation.health == .notStarted)
    #expect(processes.observation.health == .notStarted)
    #expect(repository.catalogState == .idle)
    #expect(runtime.requests.isEmpty)

    graph.urlAutomation.handleURL(
      try #require(URL(string: "finetune://set-volumes?app=unit.inactive&volume=34")))
    #expect(settings.getVolume(for: "unit.inactive") == 0.34)
    graph.bindings.editGain(identifier: "unit.inactive", gain: 0.52)
    #expect(settings.getVolume(for: "unit.inactive") == 0.52)
    #expect(graph.controller.gain(for: "unit.inactive") == 0.52)
    #expect(runtime.requests.isEmpty)
  }

  @Test("Preset metadata CRUD persists without reconfiguring active EQ or native execution")
  func presetMetadataDoesNotReconfigureAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootPresets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: GraphTestLoginService())
    let activeEQ = EQPreset.bassBoost.settings
    settings.setEQSettings(activeEQ, for: "unit.active")
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "A", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1, volume: 1,
          isMuted: false)
      ], defaultUID: "A")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: "unit.active", processID: 101, processRevision: 1,
        displayName: "Active", bundleID: "unit.active")
    ])
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("A"))
    let before = controller.routeObservations
    let committed = route.commits
    let updates = route.updates

    let bindings = RootBindings(controller: controller, settings: settings)
    let actions = bindings.appActions(activate: { _ in
      Issue.record("Preset metadata must not activate an application")
    })
    actions.createPreset("First", EQPreset.podcast.settings)
    actions.createPreset("Keep", EQPreset.trebleBoost.settings)
    let first = try #require(settings.getUserPresets().first { $0.name == "First" })
    actions.renamePreset(first.id, "Renamed")
    #expect(settings.getUserPresets().first { $0.id == first.id }?.name == "Renamed")
    actions.deletePreset(first.id)
    await controller.waitForCurrentWork()

    #expect(settings.getEQSettings(for: "unit.active") == activeEQ)
    #expect(route.commits == committed && route.updates == updates)
    #expect(controller.routeObservations == before)
    #expect(runtime.requests.count == 1)
    #expect(!route.cancelled && !route.retired)
    #expect(settings.getUserPresets().map(\.name) == ["Keep"])
    await controller.shutdown()
  }
}

@MainActor
private final class GraphTestLoginService: LaunchAtLoginService {
  let isEnabled = false
  func setEnabled(_ enabled: Bool) throws {
    Issue.record("ApplicationGraph wiring tests must not mutate login registration.")
  }
}
