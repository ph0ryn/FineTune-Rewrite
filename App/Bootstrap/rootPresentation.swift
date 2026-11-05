import AppKit
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Observation

/// Read-through UI projection over Root's actual owners; no service lifecycle or audio state lives here.
@MainActor @Observable
final class RootPresentation {
  private let graph: ApplicationGraph
  private let devices: DeviceControlModel
  private let native: NativeAudioRoutingRuntime
  private let accessibility: any AccessibilityTrustProviding
  private let mediaKeyStatus: MediaKeyStatus
  private let lifecycle: LifecycleCoordinator
  private let hasCaptureUsageDescription: Bool
  private let applicationIcon: (String?) -> NSImage?
  var applicationActivationFailure: String?
  private var revision: UInt64 = 0

  init(
    graph: ApplicationGraph, devices: DeviceControlModel, native: NativeAudioRoutingRuntime,
    accessibility: any AccessibilityTrustProviding, mediaKeyStatus: MediaKeyStatus,
    lifecycle: LifecycleCoordinator, hasCaptureUsageDescription: Bool,
    applicationIcon: @escaping (String?) -> NSImage?
  ) {
    self.graph = graph
    self.devices = devices
    self.native = native
    self.accessibility = accessibility
    self.mediaKeyStatus = mediaKeyStatus
    self.lifecycle = lifecycle
    self.hasCaptureUsageDescription = hasCaptureUsageDescription
    self.applicationIcon = applicationIcon
  }

  /// Root calls this after a non-Observable diagnostic changes; snapshots still read the real owner.
  func invalidate() { revision &+= 1 }

  func mixerSnapshot() -> MixerSnapshot {
    _ = revision
    let notice = captureNotice
    return MixerSnapshot(
      apps: applications, outputDevices: devices.outputDevices, inputDevices: devices.inputDevices,
      settings: graph.settings.appSettings, userPresets: graph.settings.getUserPresets(),
      error: error(excluding: notice?.message), backend: devices.backend, captureNotice: notice)
  }

  func settingsSnapshot() -> SettingsSnapshot {
    _ = revision
    return SettingsSnapshot(
      settings: graph.settings.appSettings, isAccessibilityTrusted: accessibility.isTrusted,
      isMediaKeyOffline: mediaKeyStatus.isOffline, error: error(excluding: nil),
      device: devices.backend)
  }

  var deviceActions: MixerDeviceActions {
    let controller = graph.controller
    return MixerDeviceActions(
      setDefault: { controller.perform(.setDefaultDevice(scope: $0.commandScope, uid: $1)) },
      setVolume: { controller.perform(.setDeviceGain(scope: $0.commandScope, uid: $1, gain: $2)) },
      setMute: { controller.perform(.setDeviceMuted(scope: $0.commandScope, uid: $1, muted: $2)) },
      setHidden: {
        controller.perform(.setDeviceHidden(scope: $0.commandScope, uid: $1, hidden: $2))
      },
      setPriority: {
        controller.perform(.setDevicePriority(scope: $0.commandScope, connectedUIDs: $1))
      },
      setIcon: { controller.perform(.setDeviceIcon(uid: $0, symbol: $1)) },
      setVolumeOverride: { controller.perform(.setDeviceVolumeOverride(uid: $0, tier: $1)) },
      stepVolume: {
        controller.perform(.stepDeviceVolume(scope: $0.commandScope, uid: $1, isUp: $2, shift: $3))
      })
  }

  private var applications: [MixerAppPresentation] {
    var rows = graph.engine.apps.map { app in
      application(
        identifier: app.persistenceIdentifier, name: app.name, icon: app.icon, isActive: true)
    }
    var included = Set(rows.map(\.id))
    for info in graph.settings.getPinnedAppInfo() + graph.settings.getIgnoredAppInfo()
    where included.insert(info.persistenceIdentifier).inserted {
      rows.append(
        application(
          identifier: info.persistenceIdentifier, name: info.displayName,
          icon: applicationIcon(info.bundleID), isActive: false
        ))
    }
    // Presentation has no alternate app-order policy: stable display name, then persistent identity.
    return rows.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
  }

  private func application(
    identifier: String, name: String, icon: NSImage?, isActive: Bool
  ) -> MixerAppPresentation {
    let settings = graph.settings
    let savedUID = settings.getDeviceRouting(for: identifier)
    let selected =
      settings.getSelectedDeviceUIDs(for: identifier) ?? Set(savedUID.map { [$0] } ?? [])
    return MixerAppPresentation(
      id: identifier, name: name, icon: icon, isActive: isActive,
      gain: graph.controller.gain(for: identifier),
      isMuted: graph.controller.isMuted(for: identifier),
      boost: graph.controller.boost(for: identifier),
      selectionMode: settings.getDeviceSelectionMode(for: identifier) ?? .single,
      isFollowingDefault: settings.isFollowingDefault(for: identifier),
      selectedDeviceUIDs: selected,
      eqSettings: settings.getEQSettings(for: identifier), isPinned: settings.isPinned(identifier),
      isIgnored: settings.isIgnored(identifier), routeStatus: routeStatus(for: identifier),
      peakLevel: peakLevel(for: identifier, isActive: isActive))
  }

  private func peakLevel(for identifier: String, isActive: Bool) -> Float? {
    let controller = graph.controller
    guard isActive, graph.processes.observation.health == .healthy,
      graph.devices.observation.health == .healthy,
      controller.applicationObservationFailure == nil, controller.outputObservationFailure == nil
    else { return nil }
    let routes = controller.routeObservations.values.filter { $0.key.appIdentifier == identifier }
    guard let generation = routes.map(\.key.generation).max() else { return nil }
    return routes.compactMap { route -> Float? in
      guard route.key.generation == generation, route.phase == .firstApplied,
        route.failure == nil, route.cleanupFailure == nil,
        let peak = route.peakLevel, peak.isFinite, peak >= 0
      else { return nil }
      return peak
    }.max()
  }

  private func routeStatus(for identifier: String) -> String? {
    let controller = graph.controller
    let observations = controller.routeObservations.values.filter {
      $0.key.appIdentifier == identifier
    }
    let generation = observations.map(\.key.generation).max()
    let hasCurrentFailure = controller.routeFailures[identifier] != nil
    var messages = [currentFailureMessage(for: identifier)].compactMap { $0 }
    // A newer prepared owner is not recovery. Keep the current fault's cleanup context until commit.
    messages += observations.filter { hasCurrentFailure || $0.key.generation == generation }
      .sorted { ($0.key.deviceUID, $0.key.generation) < ($1.key.deviceUID, $1.key.generation) }
      .compactMap { $0.cleanupFailure.map { failureMessage($0, isCleanup: true) } }
    if !hasCurrentFailure,
      observations.contains(where: {
        $0.key.generation == generation && $0.phase == .failed
          && $0.failure == nil && $0.cleanupFailure == nil
      })
    {
      messages.append("Audio routing failed.")
    }
    var included: Set<String> = []
    messages = messages.filter { included.insert($0).inserted }
    return messages.isEmpty ? nil : messages.joined(separator: "\n")
  }

  private func currentFailureMessage(for identifier: String) -> String? {
    let controller = graph.controller
    guard let failure = controller.routeFailures[identifier] else { return nil }
    let observations = controller.routeObservations.values.filter {
      $0.key.appIdentifier == identifier
    }
    let cleanupOnly =
      !observations.contains { $0.failure == failure }
      && observations.contains { $0.cleanupFailure == failure }
    return failureMessage(failure, isCleanup: cleanupOnly)
  }

  private func error(excluding notice: String?) -> String? {
    let controller = graph.controller
    var messages: [String?] = [
      controller.commandFailure?.message, controller.applicationObservationFailure?.message,
      controller.outputObservationFailure?.message,
    ]
    messages += controller.routeFailures.keys.sorted().map { currentFailureMessage(for: $0) }
    messages += [
      native.lastCleanupFailure?.failure.map { failureMessage($0) },
      native.lastCleanupFailure?.cleanupFailure.map { failureMessage($0, isCleanup: true) },
      graph.settings.lastLoadError, graph.settings.lastSaveError,
      graph.settings.lastLaunchAtLoginError, devices.lastError, lifecycle.lastError,
      applicationActivationFailure,
    ]
    let routes = controller.routeObservations.values.sorted {
      let lhs = $0.key
      let rhs = $1.key
      if lhs.appIdentifier != rhs.appIdentifier { return lhs.appIdentifier < rhs.appIdentifier }
      if lhs.deviceUID != rhs.deviceUID { return lhs.deviceUID < rhs.deviceUID }
      return lhs.generation < rhs.generation
    }
    // Primary history is not current failure state; genuine cleanup diagnostics remain distinct.
    messages += routes.compactMap { route in
      route.cleanupFailure.map { failureMessage($0, isCleanup: true) }
    }
    var included: Set<String> = []
    let visible = messages.compactMap { $0 }.filter {
      $0 != notice && included.insert($0).inserted
    }
    return visible.isEmpty ? nil : visible.joined(separator: "\n")
  }

  private func failureMessage(_ failure: AudioRouteFailure, isCleanup: Bool = false) -> String {
    let stageLabel = isCleanup ? "cleanup stage" : "stage"
    if let code = failure.code {
      return "\(failure.message) (\(stageLabel): \(failure.stage), native code: \(code))"
    }
    return "\(failure.message) (\(stageLabel): \(failure.stage))"
  }

  private var captureNotice: MixerCaptureNotice? {
    if !hasCaptureUsageDescription {
      return MixerCaptureNotice(
        message:
          "Live audio is unavailable in this executable. Use the built FineTune Rewrite app.",
        action: nil)
    }
    if graph.controller.knownPermissionDenied {
      return MixerCaptureNotice(
        message:
          "Audio capture permission was denied. Review FineTune’s access in System Settings.",
        action: .openSettings)
    }
    if let failure = graph.controller.captureRetryFailure {
      return MixerCaptureNotice(message: failureMessage(failure), action: .retryCapture)
    }
    if let failure = graph.controller.lastFailure,
      failure.kind == .unavailable || failure.kind == .unsupported
    {
      return MixerCaptureNotice(message: failure.message, action: nil)
    }
    if graph.controller.captureIntent == .none {
      return MixerCaptureNotice(
        message: "Enable live audio processing to control app audio.", action: .requestPermission)
    }
    return nil
  }
}

extension MixerDeviceScope {
  fileprivate var commandScope: AudioDeviceScope { self == .input ? .input : .output }
}
