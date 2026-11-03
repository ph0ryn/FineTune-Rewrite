import FineTuneDomain
import Observation

/// One synchronous desired-state entry point; only the separately owned native effects await.
@Observable @MainActor
public final class AudioController: AudioCommandHandling {
  let settingsStore: any AudioControlSettingsStore
  let runtime: (any AudioRoutingRuntime)?
  let profileLookup: @MainActor (String) -> AutoEQProfile?
  let deviceCommand: (@MainActor (AudioCommand) throws -> Void)?
  public let volumeState: VolumeState
  public private(set) var applications: [AudioApplicationDescriptor] = []
  public private(set) var outputs: [AudioOutputDescriptor] = []
  public private(set) var defaultOutputUID: String?
  public private(set) var captureIntent: AudioCaptureIntent = .none
  public internal(set) var knownPermissionDenied = false
  public internal(set) var routeObservations: [AudioRouteKey: AudioRouteObservation] = [:]
  public internal(set) var commandFailure: AudioRouteFailure?
  public internal(set) var applicationObservationFailure: AudioRouteFailure?
  public internal(set) var outputObservationFailure: AudioRouteFailure?
  public internal(set) var routeFailure: AudioRouteFailure?
  var hasApplications = false
  var hasOutputs = false
  var revision: UInt64 = 1
  var appRevisions: [String: UInt64] = [:]
  var generations: [String: UInt64] = [:]
  var plans: [String: AudioRoutePlan] = [:]
  var owned: [AudioRouteKey: ManagedAudioRoute] = [:]
  var active: [String: [String: AudioRouteKey]] = [:]
  @ObservationIgnored var routingTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var allRoutingTasks: [AudioRouteWorkID: Task<Void, Never>] = [:]
  @ObservationIgnored var updateTasks: [AudioRouteKey: Task<Void, Never>] = [:]
  @ObservationIgnored var retirementTasks: [AudioRouteKey: Task<Void, any Error>] = [:]
  @ObservationIgnored var armWaiters: [AudioRouteKey: CheckedContinuation<Void, any Error>] = [:]
  @ObservationIgnored var retirementWaiters: [AudioRouteKey: CheckedContinuation<Void, any Error>] =
    [:]

  public init(
    settings: any AudioControlSettingsStore, runtime: (any AudioRoutingRuntime)?,
    profileLookup: @escaping @MainActor (String) -> AutoEQProfile?,
    deviceCommand: (@MainActor (AudioCommand) throws -> Void)? = nil
  ) {
    settingsStore = settings
    self.runtime = runtime
    self.profileLookup = profileLookup
    self.deviceCommand = deviceCommand
    volumeState = VolumeState(settingsManager: settings)
    if settings.appSettings.explicitUserCaptureEnabled {
      captureIntent = .userInitiated(sessionID: UInt64.random(in: 1...UInt64.max))
    }
  }

  public var lastFailure: AudioRouteFailure? {
    commandFailure ?? applicationObservationFailure ?? outputObservationFailure ?? routeFailure
  }

  public var unavailableAutoEQProfiles: [String: String] {
    _ = revision
    return Dictionary(
      uniqueKeysWithValues: outputs.compactMap { output in
        guard output.supportsAutoEQ,
          let selection = settingsStore.getAutoEQSelection(for: output.uid), selection.isEnabled,
          profileLookup(selection.profileID) == nil
        else { return nil }
        return (output.uid, selection.profileID)
      })
  }

  public func gain(for identifier: String) -> Float {
    if let app = app(identifier) { return volumeState.getVolume(for: app.processID) }
    return settingsStore.getVolume(for: identifier) ?? settingsStore.appSettings.defaultNewAppVolume
  }

  public func isMuted(for identifier: String) -> Bool {
    if let app = app(identifier) { return volumeState.getMute(for: app.processID) }
    return settingsStore.getMute(for: identifier) ?? false
  }

  public func boost(for identifier: String) -> BoostLevel {
    if let app = app(identifier) { return volumeState.getBoost(for: app.processID) }
    return settingsStore.getBoost(for: identifier) ?? .x1
  }

  public func activeDeviceUIDs(for identifier: String) -> Set<String> {
    Set(
      (active[identifier] ?? [:]).compactMap { uid, key in
        guard let observation = routeObservations[key], observation.failure == nil,
          observation.phase == .committed || observation.phase == .firstApplied
        else { return nil }
        return uid
      })
  }

  /// Failure is not a successful empty enumeration. Preserve the last good identities and routes.
  public func observeApplications(_ values: [AudioApplicationDescriptor], failure: String? = nil) {
    if let failure {
      applicationObservationFailure = AudioRouteFailure(
        kind: .unavailable, stage: "applications", message: failure)
      return
    }
    guard Set(values.map(\.identifier)).count == values.count,
      values.allSatisfy({ !$0.identifier.isEmpty && $0.processID > 0 })
    else {
      applicationObservationFailure = AudioRouteFailure(
        kind: .unsupported, stage: "applications",
        message: "Invalid canonical application observation.")
      return
    }
    let previous = applications
    applications = values
    hasApplications = true
    applicationObservationFailure = nil
    volumeState.cleanup(keeping: Set(values.map(\.processID)))
    for value in values {
      if !previous.contains(where: {
        $0.identifier == value.identifier && $0.processID == value.processID
          && $0.processRevision == value.processRevision
      }) {
        volumeState.removeVolume(for: value.processID)
        restore(value)
      }
    }
    for vanished in previous where !values.contains(where: { $0.identifier == vanished.identifier })
    {
      stopRoutes(for: vanished.identifier)
    }
    reconcileAll()
  }

  public func observeOutputs(
    _ values: [AudioOutputDescriptor], defaultUID: String?, failure: String? = nil
  ) {
    if let failure {
      outputObservationFailure = AudioRouteFailure(
        kind: .unavailable, stage: "outputs", message: failure)
      return
    }
    guard Set(values.map(\.uid)).count == values.count,
      values.allSatisfy({
        !$0.uid.isEmpty && $0.processingGain.isFinite && (0...1).contains($0.processingGain)
          && ($0.volume == nil || ($0.volume!.isFinite && (0...1).contains($0.volume!)))
      })
    else {
      outputObservationFailure = AudioRouteFailure(
        kind: .unsupported, stage: "outputs", message: "Invalid output observation.")
      return
    }
    outputs = values
    defaultOutputUID = defaultUID
    hasOutputs = true
    outputObservationFailure = nil
    changed(applications.map(\.identifier))
  }

  public func perform(_ command: AudioCommand) {
    commandFailure = nil
    do {
      switch command {
      case .setGain(let identifier, let value):
        try setGain(value, identifier: identifier, unmute: false)
      case .editGain(let identifier, let value):
        try setGain(value, identifier: identifier, unmute: true)
      case .setMuted(let identifier, let muted): setMute(muted, identifier: identifier)
      case .toggleMuted(let identifier): setMute(!isMuted(for: identifier), identifier: identifier)
      case .setBoost(let identifier, let value):
        if let app = app(identifier) {
          volumeState.setBoost(for: app.processID, to: value, identifier: identifier)
        } else {
          settingsStore.setBoost(for: identifier, to: value)
        }
        changed([identifier])
      case .setEQ(let identifier, let settings):
        settingsStore.setEQSettings(settings, for: identifier)
        changed([identifier])
      case .followDefault(let identifier):
        settingsStore.setFollowDefault(for: identifier)
        changed([identifier])
      case .setRoute(let identifier, let mode, let uids):
        settingsStore.setDeviceSelectionMode(for: identifier, to: mode)
        settingsStore.setSelectedDeviceUIDs(for: identifier, to: uids)
        if let first = orderedUIDs(uids).first {
          settingsStore.setDeviceRouting(for: identifier, deviceUID: first)
        } else {
          settingsStore.setFollowDefault(for: identifier)
        }
        if let app = app(identifier) { restore(app) }
        changed([identifier])
      case .setPinned(let identifier, let pinned):
        let current = app(identifier)
        try settingsStore.setAppPinned(
          identifier, pinned: pinned, displayName: current?.displayName, bundleID: current?.bundleID
        )
      case .setIgnored(let identifier, let ignored):
        let current = app(identifier)
        try settingsStore.setAppIgnored(
          identifier, ignored: ignored, displayName: current?.displayName,
          bundleID: current?.bundleID)
        if let current {
          volumeState.removeVolume(for: current.processID)
          restore(current)
        }
        changed([identifier])
      case .stepVolume(let identifier, let isUp, let shift):
        var planner = VolumeKeyPlanner()
        if let change = planner.plan(
          event: isUp ? .volumeUp(isRepeat: false) : .volumeDown(isRepeat: false), tier: .software,
          currentGain: gain(for: identifier), currentMute: isMuted(for: identifier),
          step: settingsStore.appSettings.volumeHotkeyStep, nowNanoseconds: 0,
          stepMultiplier: shift ? 2 : 1)
        {
          if let value = change.gain { try setGain(value, identifier: identifier, unmute: false) }
          if let muted = change.mute { setMute(muted, identifier: identifier) }
        }
      case .stepSlider(let identifier, let delta):
        guard app(identifier) != nil else { return }
        guard delta.isFinite else { throw invalidCommand("The slider delta must be finite.") }
        try setGain(
          VolumeMapping.sliderToGain(
            max(0, min(1, VolumeMapping.gainToSlider(gain(for: identifier)) + Double(delta)))),
          identifier: identifier, unmute: false)
      case .setOutputDevice(let identifier, let uid):
        guard app(identifier) != nil else { return }
        perform(.setRoute(identifier: identifier, mode: .single, uids: [uid]))
      case .resetGainAndMute(let identifier):
        for id in identifier.map({ [$0] }) ?? applications.map(\.identifier) {
          try setGain(1, identifier: id, unmute: true)
        }
      case .resetAllSettings:
        suspend()
        settingsStore.resetAllSettings()
        volumeState.cleanup(keeping: [])
        for application in applications { restore(application) }
        revision &+= 1
      case .updateAppSettings(let settings):
        let oldWish = settingsStore.appSettings.explicitUserCaptureEnabled
        settingsStore.updateAppSettings(settings)
        if oldWish != settings.explicitUserCaptureEnabled {
          if settings.explicitUserCaptureEnabled { resume() } else { suspend() }
        }
        changed(applications.map(\.identifier))
      case .setAutoEQSelection(let uid, let selection):
        settingsStore.setAutoEQSelection(for: uid, to: selection)
        changed(applications.map(\.identifier))
      case .setAutoEQPreampEnabled(let enabled):
        settingsStore.autoEQPreampEnabled = enabled
        changed(applications.map(\.identifier))
      case .setAutoEQFavorite(let profileID, let favorite):
        settingsStore.setAutoEQFavorite(profileID: profileID, favorite: favorite)
      case .profileAvailabilityChanged:
        changed(applications.map(\.identifier))
      case .requestCaptureStart:
        var settings = settingsStore.appSettings
        settings.explicitUserCaptureEnabled = true
        settingsStore.updateAppSettings(settings)
        if captureIntent == .none || knownPermissionDenied {
          knownPermissionDenied = false
          captureIntent = .userInitiated(sessionID: UInt64.random(in: 1...UInt64.max))
        }
        reconcileAll()
      case .stopCapture:
        var settings = settingsStore.appSettings
        settings.explicitUserCaptureEnabled = false
        settingsStore.updateAppSettings(settings)
        suspend()
      default:
        guard let deviceCommand else {
          throw AudioRouteFailure(
            kind: .unavailable, stage: "device-command",
            message: "The device command backend is unavailable.")
        }
        try deviceCommand(command)
      }
    } catch { commandFailure = failure(error, stage: "command") }
  }

  /// Internal lifecycle stop, unlike the explicit user command, preserves the durable wish.
  public func suspend() {
    captureIntent = .none
    for identifier in Set(applications.map(\.identifier)).union(owned.keys.map(\.appIdentifier)) {
      stopRoutes(for: identifier)
    }
  }

  public func resume() {
    guard settingsStore.appSettings.explicitUserCaptureEnabled, !knownPermissionDenied else {
      return
    }
    if captureIntent == .none {
      captureIntent = .userInitiated(sessionID: UInt64.random(in: 1...UInt64.max))
    }
    reconcileAll()
  }

  /// Awaits the current work snapshot; an idle replacement intentionally waits for its armed callback.
  public func waitForCurrentWork() async {
    for task in Array(allRoutingTasks.values) { await task.value }
    for task in Array(updateTasks.values) { await task.value }
  }

  public func shutdown() async {
    suspend()
    // Superseded preparation remains owned too: a late return must retire before shutdown finishes.
    await waitForCurrentWork()
    for task in Array(retirementTasks.values) {
      do { try await task.value } catch { routeFailure = failure(error, stage: "retire") }
    }
  }

  func app(_ identifier: String) -> AudioApplicationDescriptor? {
    applications.first { $0.identifier == identifier }
  }
  func restore(_ app: AudioApplicationDescriptor) {
    volumeState.loadSavedVolume(for: app.processID, identifier: app.identifier)
    volumeState.loadSavedMute(for: app.processID, identifier: app.identifier)
    volumeState.loadSavedBoost(for: app.processID, identifier: app.identifier)
    volumeState.loadSavedDeviceSelectionMode(for: app.processID, identifier: app.identifier)
    volumeState.loadSavedSelectedDeviceUIDs(for: app.processID, identifier: app.identifier)
  }
  func setGain(_ value: Float, identifier: String, unmute: Bool) throws {
    guard !identifier.isEmpty, value.isFinite, (0...1).contains(value) else {
      throw invalidCommand("App gain must be finite and within 0...1.")
    }
    if let app = app(identifier) {
      volumeState.setVolume(for: app.processID, to: value, identifier: identifier)
    } else {
      settingsStore.setVolume(for: identifier, to: value)
    }
    if unmute {
      if let app = app(identifier) {
        volumeState.setMute(for: app.processID, to: false, identifier: identifier)
      } else {
        settingsStore.setMute(for: identifier, to: false)
      }
    }
    changed([identifier])
  }
  func setMute(_ value: Bool, identifier: String) {
    if let app = app(identifier) {
      volumeState.setMute(for: app.processID, to: value, identifier: identifier)
    } else {
      settingsStore.setMute(for: identifier, to: value)
    }
    changed([identifier])
  }
  func orderedUIDs(_ values: Set<String>) -> [String] {
    let priority = settingsStore.devicePriorityOrder
    return values.sorted {
      let lhs = priority.firstIndex(of: $0) ?? Int.max
      let rhs = priority.firstIndex(of: $1) ?? Int.max
      return lhs == rhs ? $0 < $1 : lhs < rhs
    }
  }
  func invalidCommand(_ message: String) -> AudioRouteFailure {
    AudioRouteFailure(kind: .unsupported, stage: "command", message: message)
  }
  func failure(_ error: any Error, stage: String) -> AudioRouteFailure {
    error as? AudioRouteFailure
      ?? AudioRouteFailure(stage: stage, message: String(describing: error))
  }
}

@MainActor
final class ManagedAudioRoute {
  let handle: any PreparedAudioRoute
  let key: AudioRouteKey
  let processRevision: UInt64
  let sessionID: UInt64
  var output: AudioOutputDescriptor
  init(
    handle: any PreparedAudioRoute, processRevision: UInt64, sessionID: UInt64,
    output: AudioOutputDescriptor
  ) {
    self.handle = handle
    key = handle.key
    self.processRevision = processRevision
    self.sessionID = sessionID
    self.output = output
  }
}
