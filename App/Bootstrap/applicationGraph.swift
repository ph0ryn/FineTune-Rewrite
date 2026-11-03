import FineTuneControl
import FineTunePlatform

/// Required service wiring only. The shared lifecycle and AppKit host own start/stop effects.
@MainActor
final class ApplicationGraph {
  let settings: SettingsManager
  let profiles: AutoEQProfileRepository
  let devices: any AudioDeviceObservationProviding
  let processes: any AudioProcessObservationProviding
  let volumes: any DeviceVolumeProviding
  let controller: AudioController
  let engine: AudioEngine
  let bindings: RootBindings
  let urlAutomation: URLAutomationController
  let autoEQAutomation: AutoEQAutomation

  init(
    settings: SettingsManager, profiles: AutoEQProfileRepository,
    devices: any AudioDeviceObservationProviding,
    processes: any AudioProcessObservationProviding, volumes: any DeviceVolumeProviding,
    runtime: any AudioRoutingRuntime,
    deviceCommand: @escaping @MainActor (AudioCommand) throws -> Void
  ) {
    self.settings = settings
    self.profiles = profiles
    self.devices = devices
    self.processes = processes
    self.volumes = volumes
    let cache = profiles.cache
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { cache.profile(for: $0) },
      deviceCommand: deviceCommand)
    self.controller = controller
    engine = AudioEngine(
      controller: controller, settingsManager: settings, deviceObservations: devices,
      processObservations: processes, deviceVolumeMonitor: volumes)
    bindings = RootBindings(controller: controller)
    urlAutomation = URLAutomationController(commandHandler: controller)
    autoEQAutomation = AutoEQAutomation(
      repository: profiles, preferences: settings, commands: controller,
      connectedDeviceUIDs: { devices.observation.outputDevices.map(\.uid) })
  }
}
