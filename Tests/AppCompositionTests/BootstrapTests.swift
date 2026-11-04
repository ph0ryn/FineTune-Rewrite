import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("Production Root command bindings", .timeLimit(.minutes(1)))
@MainActor
struct BootstrapTests {
  @Test(
    "Consecutive settings callbacks and an inactive gain edit reach one real store synchronously")
  func settingsCallbacksDoNotLoseEarlierWishes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootBindings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: BootstrapBindingLoginService())
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let bindings = RootBindings(controller: controller, settings: settings)

    var first = settings.appSettings
    first.defaultNewAppVolume = 0.37
    bindings.updateSettings(first)
    var second = settings.appSettings
    second.mediaKeyControlEnabled = false
    bindings.updateSettings(second)
    controller.perform(.setMuted(identifier: "unit.pinned-inactive", muted: true))
    bindings.editGain(identifier: "unit.pinned-inactive", gain: 0.42)

    #expect(bindings.controller === controller)
    #expect(settings.appSettings.defaultNewAppVolume == 0.37)
    #expect(!settings.appSettings.mediaKeyControlEnabled)
    #expect(settings.getVolume(for: "unit.pinned-inactive") == 0.42)
    #expect(settings.getMute(for: "unit.pinned-inactive") == false)
    settings.flushSync()
    #expect(settings.lastSaveError == nil)
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    #expect(saved.appSettings.defaultNewAppVolume == 0.37)
    #expect(!saved.appSettings.mediaKeyControlEnabled)
    #expect(saved.appVolumes["unit.pinned-inactive"] == 0.42)
    #expect(saved.appMutes["unit.pinned-inactive"] == false)
  }

  @Test("Cold Root graph shares the real store, cache, Controller and observer instances")
  func oneActualGraphWithoutStartingOSServices() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootGraph-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: BootstrapBindingLoginService())
    let cache = AutoEQProfileCache()
    let repository = try AutoEQProfileRepository(
      directory: directory.appendingPathComponent("Profiles"), cache: cache)
    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    let volumes = CoreAudioDeviceVolumeAdapter(
      deviceProvider: devices, settingsManager: settings)
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
      try #require(
        URL(
          string: "finetune://set-volumes?app=unit.inactive&volume=34")))
    #expect(settings.getVolume(for: "unit.inactive") == 0.34)
    graph.bindings.editGain(identifier: "unit.inactive", gain: 0.52)
    #expect(settings.getVolume(for: "unit.inactive") == 0.52)
    #expect(graph.controller.gain(for: "unit.inactive") == 0.52)
    #expect(runtime.requests.isEmpty)
    settings.flushSync()
    #expect(settings.lastSaveError == nil)
  }

  @Test("Preset metadata CRUD persists without changing copied active EQ or native execution")
  func presetMetadataDoesNotReconfigureAudio() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootPresets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: BootstrapBindingLoginService())
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
    let actions = bindings.appActions
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
    settings.flushSync()
    let restored = SettingsManager(
      directory: directory, launchAtLoginService: BootstrapBindingLoginService())
    #expect(restored.getUserPresets().count == 1)
    #expect(restored.getUserPresets().first?.name == "Keep")
    #expect(restored.getEQSettings(for: "unit.active") == activeEQ)
    #expect(restored.appSettings.explicitUserCaptureEnabled)
    await controller.shutdown()
  }

  @Test("Blocked preparation cannot delay Root wishes or commit stale gain and cached correction")
  func callbacksWhilePreparationIsBlocked() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRootBlocked-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: BootstrapBindingLoginService())
    let initialProfile = AutoEQProfile(
      id: "unit-profile", name: "Initial", source: .imported, preampDB: -3, filters: [])
    let cache = AutoEQProfileCache(profiles: [initialProfile])
    settings.setAutoEQSelection(
      for: "A", to: AutoEQSelection(profileID: initialProfile.id, isEnabled: true))
    let runtime = RoutingProbeRuntime()
    runtime.holdPreparation = ["A"]
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { cache.profile(for: $0) },
      readDefaultRoutingDecision: { .followObserved })
    let bindings = RootBindings(controller: controller, settings: settings)
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "A", bindingRevision: 1, supportsAutoEQ: true, processingGain: 1, volume: 1,
          isMuted: false)
      ], defaultUID: "A")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: "unit.active", processID: 101, processRevision: 1,
        displayName: "Active", bundleID: "unit.active")
    ])
    controller.perform(.requestCaptureStart)
    await runtime.wait("prepare:A")
    #expect(runtime.requests.first?.initialState.processing.autoEQProfile == initialProfile)

    var first = settings.appSettings
    first.loudnessCompensationEnabled = true
    bindings.updateSettings(first)
    var second = settings.appSettings
    second.defaultNewAppVolume = 0.23
    bindings.updateSettings(second)
    bindings.editGain(identifier: "unit.active", gain: 0.42)
    let latestProfile = AutoEQProfile(
      id: initialProfile.id, name: "Latest", source: .imported, preampDB: -6, filters: [])
    cache.store(latestProfile)
    controller.perform(.profileAvailabilityChanged(profileID: latestProfile.id))

    #expect(settings.appSettings.loudnessCompensationEnabled)
    #expect(settings.appSettings.defaultNewAppVolume == 0.23)
    #expect(settings.appSettings.explicitUserCaptureEnabled)
    #expect(settings.getVolume(for: "unit.active") == 0.42)
    settings.flushSync()
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    #expect(saved.appSettings.loudnessCompensationEnabled)
    #expect(saved.appSettings.defaultNewAppVolume == 0.23)
    #expect(saved.appVolumes["unit.active"] == 0.42)

    runtime.releasePreparation("A")
    await controller.waitForCurrentWork()
    let committed = try #require(runtime.handle("A")?.commits.last)
    #expect(committed.effectiveGain == 0.42)
    #expect(committed.processing.autoEQProfile == latestProfile)
    #expect(committed.processing.loudnessCompensationEnabled)
    #expect(runtime.requests.count == 1)
    await controller.shutdown()
    #expect(settings.appSettings.explicitUserCaptureEnabled)
  }
}

@MainActor
private final class BootstrapBindingLoginService: LaunchAtLoginService {
  let isEnabled = false
  func setEnabled(_ enabled: Bool) throws {
    Issue.record("The Root binding unit must not mutate login registration.")
  }
}
