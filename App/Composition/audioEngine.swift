import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Observation

/// Correction availability is an observation; it never rewrites the saved device selection.
enum AutoEQAvailability: Equatable {
  case notSelected, unsupportedDevice, disabled
  case available(profileID: String)
  case unavailable(profileID: String)
}

struct AppRouteSnapshot: Equatable {
  var deviceUIDs: [String]
  var initialState: TapInitialState?
  var autoEQ: AutoEQAvailability
  var isActive: Bool
  var failure: String?
}

/// App composition joins concrete OS adapters to the Control state and runtime ports.
/// It does not implement an audio callback, persistence schema, or a second volume model.
@Observable
@MainActor
final class AudioEngine {
  enum RouteError: Error {
    case liveRuntimeUnavailable, authorizationUnknown, authorizationDenied
    case outputUnavailable(String)
  }
  typealias TapFactory =
    @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

  let volumeState: VolumeState
  private(set) var apps: [AudioApp]
  private(set) var routeSnapshots: [Int32: AppRouteSnapshot] = [:]
  let deviceVolumeMonitor: any DeviceVolumeProviding

  private let settingsManager: SettingsManager
  private let permission: AudioCaptureAuthorization
  private let profiles: AutoEQProfileCache
  private let deviceProvider: any AudioDeviceProviding
  private let processMonitor: any AudioProcessMonitoring
  private let tapFactory: TapFactory
  private var taps: [Int32: any ProcessTapControlling] = [:]

  init(
    permission: AudioCaptureAuthorization? = nil, settingsManager: SettingsManager,
    autoEQProfileManager: AutoEQProfileCache? = nil,
    deviceProvider: (any AudioDeviceProviding)? = nil,
    processMonitor: (any AudioProcessMonitoring)? = nil,
    deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
    tapFactory: TapFactory? = nil, startMonitorsAutomatically: Bool = true
  ) {
    let devices = deviceProvider ?? AudioDeviceMonitor()
    let processes = processMonitor ?? AudioProcessMonitor()
    self.permission = permission ?? AudioCaptureAuthorization()
    self.settingsManager = settingsManager
    self.profiles = autoEQProfileManager ?? AutoEQProfileCache()
    self.deviceProvider = devices
    self.processMonitor = processes
    self.deviceVolumeMonitor =
      deviceVolumeMonitor
      ?? CoreAudioDeviceVolumeAdapter(deviceProvider: devices, settingsManager: settingsManager)
    self.tapFactory = tapFactory ?? { _, _, _ in throw RouteError.liveRuntimeUnavailable }
    self.volumeState = VolumeState(settingsManager: settingsManager)
    self.apps = processes.activeApps
    bindObservations()
    restoreAppState(apps)
    if startMonitorsAutomatically {
      devices.start()
      processes.start()
      self.deviceVolumeMonitor.start()
    }
  }

  func currentVolume(for app: AudioApp) -> Float { volumeState.getVolume(for: app.id) }
  func isMuted(for app: AudioApp) -> Bool { volumeState.getMute(for: app.id) }
  func toggleMute(for app: AudioApp) { setMute(for: app, to: !isMuted(for: app)) }

  func setVolume(for app: AudioApp, to volume: Float) {
    volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
    if let route = taps[app.id] {
      applyOutputState(route, app: app)
      route.updateLoudnessCompensation(
        volume: route.currentDeviceVolume * volume,
        enabled: settingsManager.appSettings.loudnessCompensationEnabled
      )
    }
  }

  func setMute(for app: AudioApp, to muted: Bool) {
    volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
    taps[app.id]?.isMuted = muted
  }

  func isAudibleNow(bundleID: String) -> Bool {
    apps.filter { $0.bundleID == bundleID }.contains { app in
      app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }
  }

  /// Saving the request and observing successful activation are deliberately separate operations.
  func setDevice(for app: AudioApp, deviceUID: String) {
    settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)
    var candidate: (any ProcessTapControlling)?
    do {
      switch permission.status {
      case .unknown: throw RouteError.authorizationUnknown
      case .denied: throw RouteError.authorizationDenied
      case .authorized: break
      }
      guard let device = deviceProvider.device(for: deviceUID) else {
        throw RouteError.outputUnavailable(deviceUID)
      }
      restoreAppState([app])
      let route = try tapFactory(app, [deviceUID], nil)
      candidate = route
      applyOutputState(route, app: app, device: device)
      let (initial, availability) = preparedState(app: app, device: device, route: route)
      try route.activate(initial: initial)
      let old = taps.updateValue(route, forKey: app.id)
      routeSnapshots[app.id] = AppRouteSnapshot(
        deviceUIDs: [deviceUID], initialState: initial, autoEQ: availability, isActive: true,
        failure: nil
      )
      old?.invalidate()
    } catch {
      candidate?.invalidate()
      let existing = routeSnapshots[app.id]
      routeSnapshots[app.id] = AppRouteSnapshot(
        deviceUIDs: existing?.deviceUIDs ?? [], initialState: existing?.initialState,
        autoEQ: existing?.autoEQ ?? .notSelected, isActive: existing?.isActive ?? false,
        failure: String(describing: error)
      )
    }
  }

  func shutdown() {
    for route in taps.values { route.invalidate() }
    taps.removeAll()
    for id in routeSnapshots.keys { routeSnapshots[id]?.isActive = false }
    deviceVolumeMonitor.stop()
    processMonitor.stop()
    deviceProvider.stop()
  }

  private func preparedState(
    app: AudioApp, device: AudioDevice, route: any ProcessTapControlling
  ) -> (TapInitialState, AutoEQAvailability) {
    let availability: AutoEQAvailability
    let profile: AutoEQProfile?
    if !device.supportsAutoEQ {
      availability = .unsupportedDevice
      profile = nil
    } else if let selection = settingsManager.getAutoEQSelection(for: device.uid) {
      if !selection.isEnabled {
        availability = .disabled
        profile = nil
      } else if let cached = profiles.profile(for: selection.profileID) {
        availability = .available(profileID: cached.id)
        profile = cached
      } else {
        availability = .unavailable(profileID: selection.profileID)
        profile = nil
      }
    } else {
      availability = .notSelected
      profile = nil
    }
    var loudness = LoudnessEqualizerSettings()
    loudness.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
    return (
      TapInitialState(
        eqSettings: settingsManager.getEQSettings(for: app.persistenceIdentifier),
        autoEQProfile: profile, autoEQPreampEnabled: settingsManager.autoEQPreampEnabled,
        loudnessVolume: route.currentDeviceVolume * volumeState.getVolume(for: app.id),
        loudnessCompensationEnabled: settingsManager.appSettings.loudnessCompensationEnabled,
        loudnessEqualizerSettings: loudness
      ), availability
    )
  }

  private func applyOutputState(
    _ route: any ProcessTapControlling, app: AudioApp, device: AudioDevice? = nil
  ) {
    let output = device ?? route.currentDeviceUID.flatMap { deviceProvider.device(for: $0) }
    let processingGain = output.map { deviceVolumeMonitor.outputProcessingGain(for: $0.id) } ?? 1
    route.volume =
      volumeState.getVolume(for: app.id) * volumeState.getBoost(for: app.id).rawValue
      * processingGain
    route.isMuted = volumeState.getMute(for: app.id)
    route.currentDeviceVolume = output.flatMap { deviceVolumeMonitor.volumes[$0.id] } ?? 1
    route.isDeviceMuted = output.flatMap { deviceVolumeMonitor.muteStates[$0.id] } ?? false
  }

  private func restoreAppState(_ apps: [AudioApp]) {
    for app in apps {
      let identifier = app.persistenceIdentifier
      volumeState.loadSavedVolume(for: app.id, identifier: identifier)
      volumeState.loadSavedMute(for: app.id, identifier: identifier)
      volumeState.loadSavedBoost(for: app.id, identifier: identifier)
      volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: identifier)
      volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: identifier)
    }
  }

  private func bindObservations() {
    processMonitor.onAppsChanged = { [weak self] apps in
      guard let self else { return }
      let activeProcesses = Set(apps.map(\.id))
      let departed = self.taps.filter { !activeProcesses.contains($0.key) }
      for (id, route) in departed {
        route.invalidate()
        self.taps.removeValue(forKey: id)
      }
      self.routeSnapshots = self.routeSnapshots.filter { activeProcesses.contains($0.key) }
      self.volumeState.cleanup(keeping: activeProcesses)
      self.apps = apps
      self.restoreAppState(apps)
    }
    deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, _ in
      guard let self else { return }
      for route in self.taps.values {
        guard
          route.currentDeviceUIDs.contains(where: {
            self.deviceProvider.device(for: $0)?.id == deviceID
          })
        else { continue }
        self.applyOutputState(route, app: route.app)
        route.updateLoudnessCompensation(
          volume: route.currentDeviceVolume * self.currentVolume(for: route.app),
          enabled: self.settingsManager.appSettings.loudnessCompensationEnabled
        )
      }
    }
    deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, muted in
      guard let self else { return }
      for route in self.taps.values
      where route.currentDeviceUIDs.contains(where: {
        self.deviceProvider.device(for: $0)?.id == deviceID
      }) {
        route.isDeviceMuted = muted
      }
    }
    deviceProvider.onDeviceDisconnected = { [weak self] uid, _ in
      guard let self else { return }
      let affected = self.taps.filter { $0.value.currentDeviceUIDs.contains(uid) }
      for (id, route) in affected {
        route.invalidate()
        self.taps.removeValue(forKey: id)
        self.routeSnapshots[id]?.isActive = false
        self.routeSnapshots[id]?.failure = "Output unavailable: \(uid)"
      }
    }
  }
}
