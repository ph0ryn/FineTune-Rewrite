import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Observation

/// App composition only. Root owns the device/output producers and their single-slot fanouts.
@MainActor @Observable
final class DeviceControlModel {
  private let settings: SettingsManager
  private let devices: any AudioDeviceProviding
  private let output: CoreAudioDeviceVolumeAdapter
  private let input: InputDeviceBackend
  private let systemSounds: SystemSoundBackend
  private let alertVolume: AlertVolumeBackend
  private let alertSilencing: SystemAlertSilencing
  private let bluetooth: BluetoothDeviceBackend
  private let ddc: DDCVolumeBackend
  /// Reused when Root constructs the actual inspector; projection never performs a metadata query.
  let inspectorReader: any AudioDevicePropertyReading
  private let selectPreferredInput: @MainActor (String) throws -> Void
  private let inputPreferencesDidChange: @MainActor () -> Void
  private let selectDefaultOutput: @MainActor (String) throws -> Void
  private let outputPreferencesDidChange: @MainActor () -> Void
  private let readOutputSelectionFailure: @MainActor () -> String?
  private var commandError: String?
  private(set) var isRunning = false
  /// Presentation invalidation only. Calling a producer/refresh from this callback would form a loop.
  var onChange: (() -> Void)?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var probeInputs: [ProbeInput] = []

  private struct ProbeInput: Equatable {
    let uid: String
    let id: AudioDeviceID
    let name: String
    let transport: TransportType
  }

  init(
    settings: SettingsManager, devices: any AudioDeviceProviding,
    output: CoreAudioDeviceVolumeAdapter, input: InputDeviceBackend,
    systemSounds: SystemSoundBackend, alertVolume: AlertVolumeBackend,
    bluetooth: BluetoothDeviceBackend, ddc: DDCVolumeBackend,
    reader: any AudioDevicePropertyReading,
    selectPreferredInput: @escaping @MainActor (String) throws -> Void,
    inputPreferencesDidChange: @escaping @MainActor () -> Void,
    selectDefaultOutput: @escaping @MainActor (String) throws -> Void,
    outputPreferencesDidChange: @escaping @MainActor () -> Void,
    readOutputSelectionFailure: @escaping @MainActor () -> String? = { nil }
  ) {
    self.settings = settings
    self.devices = devices
    self.output = output
    self.input = input
    self.systemSounds = systemSounds
    self.alertVolume = alertVolume
    self.alertSilencing = SystemAlertSilencing(
      alertVolume: alertVolume, settings: settings)
    self.bluetooth = bluetooth
    self.ddc = ddc
    inspectorReader = reader
    self.selectPreferredInput = selectPreferredInput
    self.inputPreferencesDidChange = inputPreferencesDidChange
    self.selectDefaultOutput = selectDefaultOutput
    self.outputPreferencesDidChange = outputPreferencesDidChange
    self.readOutputSelectionFailure = readOutputSelectionFailure
  }

  var lastError: String? {
    commandError ?? readOutputSelectionFailure() ?? output.lastError?.localizedDescription
      ?? input.lastError?.localizedDescription
      ?? systemSounds.lastError?.localizedDescription ?? alertVolume.lastError?.localizedDescription
      ?? alertSilencing.lastError
      ?? bluetooth.lastError?.localizedDescription ?? ddc.lastError?.localizedDescription
  }

  var outputDevices: [MixerDevicePresentation] {
    ordered(devices.outputDevices, priority: settings.devicePriorityOrder).map { device in
      let automatic = output.cachedAutomaticOutputVolumeBackend(for: device.id)
      // Until observation, hardware is only an inert numeric curve; no value/capability is invented.
      let selected = settings.getDeviceVolumeTierOverride(for: device.uid) ?? automatic ?? .hardware
      return MixerDevicePresentation(
        device: device, transport: device.transportType,
        isDefault: output.defaultDeviceUID == device.uid,
        volume: output.volumes[device.id], isMuted: output.muteStates[device.id],
        backend: selected, automaticBackend: automatic,
        isHidden: settings.isOutputDeviceHidden(device.uid),
        iconOverride: settings.getDeviceIconOverride(for: device.uid),
        volumeOverride: settings.getDeviceVolumeTierOverride(for: device.uid),
        canSetVolume: output.canSetVolume(for: device.id),
        canSetMute: output.canSetMute(for: device.id),
        error: output.deviceError(forUID: device.uid))
    }
  }

  var inputDevices: [MixerDevicePresentation] {
    ordered(devices.inputDevices, priority: settings.inputDevicePriorityOrder).map { device in
      let state = input.states[device.uid]
      return MixerDevicePresentation(
        device: device, transport: device.transportType,
        isDefault: output.defaultInputDeviceUID == device.uid,
        volume: state?.volume, isMuted: state?.isMuted, backend: .hardware,
        automaticBackend: .hardware,
        isHidden: settings.isInputDeviceHidden(device.uid),
        iconOverride: settings.getDeviceIconOverride(for: device.uid), volumeOverride: nil,
        canSetVolume: state?.canSetVolume == true, canSetMute: state?.canSetMute == true,
        error: state?.error)
    }
  }

  var backend: DeviceSettingsPresentation {
    DeviceSettingsPresentation(
      systemOutputUID: systemSounds.outputUID,
      systemOutputOptions: outputDevices.map {
        DeviceSystemOutputOption(uid: $0.id, name: $0.device.name)
      },
      canSetSystemOutput: systemSounds.canSetOutput,
      followsDefault: settings.isSystemSoundsFollowingDefault,
      alertVolume: alertVolume.displayedVolume,
      canSetAlertVolume: alertVolume.observedVolume != nil,
      alertIsApplying: alertVolume.isApplying,
      alertVolumeSilenced: alertSilencing.isSilenced, error: lastError,
      bluetooth: BluetoothPresentation(
        isPoweredOn: bluetooth.isPoweredOn,
        paired: bluetooth.pairedDevices.map { peer in
          let phase: BluetoothConnectionState =
            switch bluetooth.connectionPhases[peer.id] ?? .idle {
            case .idle: .idle
            case .connecting: .connecting
            case .basebandConnected: .waitingForAudioDevice
            case .failed: .failed
            }
          return PairedBluetoothPresentation(
            id: peer.id, name: peer.name,
            iconSymbol: DeviceIconSymbol.iconSymbol(forName: peer.name, transport: .bluetooth),
            connectionState: phase, error: bluetooth.connectionErrors[peer.id])
        }, error: bluetooth.lastError?.localizedDescription))
  }

  var backendActions: DeviceSettingsActions {
    DeviceSettingsActions(
      setSystemOutput: { [weak self] uid in
        self?.attempt {
          guard let self else { return }
          self.settings.setSystemSoundsFollowDefault(false)
          try self.systemSounds.setOutput(forUID: uid)
        }
      },
      setSystemFollowDefault: { [weak self] in
        self?.attempt {
          guard let self else { return }
          self.settings.setSystemSoundsFollowDefault(true)
          try self.followDefaultIfNeeded()
        }
      },
      setAlertVolume: { [weak self] value in
        guard let self else { return }
        self.run { [alertVolume] in try await alertVolume.setVolume(value) }
      },
      refreshBluetooth: { [weak self] in
        guard let self else { return }
        self.run { [bluetooth] in await bluetooth.refresh() }
      },
      connectBluetooth: { [weak self] id in
        guard let self else { return }
        self.run { [bluetooth] in try await bluetooth.connect(id: id) }
      })
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    probeInputs = currentProbeInputs
    input.start()
    systemSounds.start()
    systemSounds.onOutputChanged = { [weak self] _ in
      Task { @MainActor [weak self] in self?.reconcileAlertSilencing() }
    }
    alertSilencing.start()
    reconcileAlertSilencing()
    bluetooth.start()
    ddc.start()
    attempt { try followDefaultIfNeeded() }
    trackChanges()
  }

  func stop() async {
    isRunning = false
    generation &+= 1
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    systemSounds.onOutputChanged = nil
    input.stop()
    systemSounds.stop()
    bluetooth.stop()
    await ddc.stop()
    await alertSilencing.stop()
    alertVolume.stop()
  }

  /// The AppKit will-terminate turn cannot await; alert silencing restores its OS value here.
  func prepareForTermination() {
    alertSilencing.prepareForTermination()
  }

  /// Joins the serial alert-silencing queue at lifecycle boundaries and in component tests.
  func awaitAlertSilencing() async {
    await alertSilencing.awaitTransitions()
  }

  /// A system-sounds mute that only exists inside the tap cannot silence OS alert sounds.
  private func reconcileAlertSilencing() {
    alertSilencing.update(target: systemAlertSilencingTarget)
  }

  private var systemAlertSilencingTarget: SystemAlertSilencingTarget? {
    guard let uid = systemSounds.outputUID,
      let device = devices.outputDevices.first(where: { $0.uid == uid }),
      let isMuted = output.muteStates[device.id]
    else { return nil }
    return SystemAlertSilencingTarget(
      deviceUID: uid, tier: output.outputVolumeBackend(for: device.id), isMuted: isMuted)
  }

  isolated deinit { for task in tasks.values { task.cancel() } }

  /// Root has already refreshed its shared output owner and supplied its current healthy observation.
  func devicesDidChange() {
    guard isRunning else { return }
    input.refresh()
    systemSounds.refresh()
    let next = currentProbeInputs
    if next != probeInputs {
      probeInputs = next
      ddc.devicesDidChange()
    }
    attempt { try followDefaultIfNeeded() }
    reconcileAlertSilencing()
  }

  func settingsDidChange() {
    guard isRunning else { return }
    inputPreferencesDidChange()
    outputPreferencesDidChange()
    attempt { try followDefaultIfNeeded() }
    reconcileAlertSilencing()
  }

  /// UI, URL and keyboard all arrive through the same AudioController device-command hook.
  func perform(_ command: AudioCommand) throws {
    do {
      guard isRunning else {
        throw DeviceBackendError.operationFailed("Device controls are not running.")
      }
      commandError = nil
      switch command {
      case .setDefaultDevice(let scope, let uid):
        if scope == .input {
          try selectPreferredInput(uid)
        } else {
          try selectDefaultOutput(uid)
          try followDefaultIfNeeded()
        }
      case .setDeviceGain(let scope, let uid, let gain):
        try editVolume(scope: scope, uid: uid, gain: gain)
      case .setRawDeviceGain(let scope, let uid, let gain):
        try setRawVolume(scope: scope, uid: uid, gain: gain)
      case .setDeviceMuted(let scope, let uid, let muted):
        try setMute(scope: scope, uid: uid, muted: muted)
      case .stepDeviceVolume(let scope, let uid, let up, let shift):
        let row = (scope == .input ? inputDevices : outputDevices).first { $0.id == uid }
        guard let row, let gain = row.volume, row.canSetVolume else {
          throw DeviceBackendError.unsupported("Volume readback")
        }
        var planner = VolumeKeyPlanner()
        if let change = planner.plan(
          event: up ? .volumeUp(isRepeat: false) : .volumeDown(isRepeat: false), tier: row.backend,
          currentGain: gain, currentMute: row.isMuted ?? false,
          step: settings.appSettings.volumeHotkeyStep,
          nowNanoseconds: 0, stepMultiplier: shift ? 2 : 1)
        {
          if let muted = change.mute, row.canSetMute {
            try setMute(scope: scope, uid: uid, muted: muted)
          }
          if let gain = change.gain { try editVolume(scope: scope, uid: uid, gain: gain) }
        }
      case .setDeviceHidden(let scope, let uid, let hidden):
        if scope == .input {
          if hidden {
            settings.hideInputDevice(uid: uid)
          } else {
            settings.unhideInputDevice(uid: uid)
          }
        } else {
          if hidden {
            settings.hideOutputDevice(uid: uid)
          } else {
            settings.unhideOutputDevice(uid: uid)
          }
        }
      case .setDevicePriority(let scope, let connected):
        let current = (scope == .input ? devices.inputDevices : devices.outputDevices).map(\.uid)
        guard Set(connected) == Set(current), Set(connected).count == connected.count else {
          throw DeviceBackendError.operationFailed(
            "The connected device order changed. Try reordering again.")
        }
        if scope == .input {
          settings.mergeInputDevicePriorityOrder(
            oldPriority: settings.inputDevicePriorityOrder, connectedOrder: connected)
          inputPreferencesDidChange()
        } else {
          settings.mergeDevicePriorityOrder(
            oldPriority: settings.devicePriorityOrder, connectedOrder: connected)
          outputPreferencesDidChange()
        }
      case .setDeviceIcon(let uid, let symbol): settings.setDeviceIconOverride(for: uid, to: symbol)
      case .setDeviceVolumeOverride(let uid, let tier):
        settings.setDeviceVolumeTierOverride(for: uid, to: tier)
        if let device = devices.device(for: uid) { output.applyTierOverrideChange(for: device.id) }
      default: throw DeviceBackendError.unsupported("This device command")
      }
      reconcileAlertSilencing()
      onChange?()
    } catch {
      commandError = error.localizedDescription
      reconcileAlertSilencing()
      onChange?()
      throw error
    }
  }

  private func editVolume(scope: AudioDeviceScope, uid: String, gain: Float) throws {
    guard gain.isFinite, (0...1).contains(gain) else {
      throw DeviceBackendError.invalidVolume(gain)
    }
    let row = (scope == .input ? inputDevices : outputDevices).first { $0.id == uid }
    if gain > 0, row?.isMuted == true, row?.canSetMute == true {
      // Unmute/restore precedes the new edit, so DDC's old restore cannot overwrite that edit.
      try setMute(scope: scope, uid: uid, muted: false)
    }
    try setRawVolume(scope: scope, uid: uid, gain: gain)
  }
  private func setRawVolume(scope: AudioDeviceScope, uid: String, gain: Float) throws {
    // Raw planner results preserve mute. Each real backend validates UID/range and publishes readback.
    if scope == .input {
      try input.setVolume(forUID: uid, to: gain)
    } else {
      try output.requestVolume(forUID: uid, to: gain)
    }
  }
  private func setMute(scope: AudioDeviceScope, uid: String, muted: Bool) throws {
    if scope == .input {
      try input.setMute(forUID: uid, to: muted)
    } else {
      try output.requestMute(forUID: uid, to: muted)
    }
  }
  private func followDefaultIfNeeded() throws {
    guard settings.isSystemSoundsFollowingDefault, output.hasCurrentDefaultOutput,
      let uid = output.defaultDeviceUID,
      systemSounds.outputUID != uid
    else { return }
    try systemSounds.setOutput(forUID: uid)
  }
  private func ordered(_ values: [AudioDevice], priority: [String]) -> [AudioDevice] {
    values.enumerated().sorted { left, right in
      let a = priority.firstIndex(of: left.element.uid) ?? priority.count
      let b = priority.firstIndex(of: right.element.uid) ?? priority.count
      return a == b ? left.offset < right.offset : a < b
    }.map(\.element)
  }
  private var currentProbeInputs: [ProbeInput] {
    devices.outputDevices.map {
      ProbeInput(uid: $0.uid, id: $0.id, name: $0.name, transport: $0.transportType)
    }
  }
  private func attempt(_ operation: () throws -> Void) {
    guard isRunning else { return }
    do {
      commandError = nil
      try operation()
    } catch { commandError = error.localizedDescription }
    onChange?()
  }
  private func run(_ operation: @escaping @MainActor () async throws -> Void) {
    guard isRunning else { return }
    let epoch = generation
    let ticket = UUID()
    tasks[ticket] = Task { @MainActor [weak self] in
      guard self?.isRunning == true, self?.generation == epoch, !Task.isCancelled else { return }
      do { try await operation() } catch {
        // Alert/Bluetooth publish noncancelled failures in their observable state before throwing.
        // A second error latch here would resurrect superseded results and defeat BT's timed clear.
      }
      guard let self, self.isRunning, self.generation == epoch else { return }
      self.tasks[ticket] = nil
      self.onChange?()
    }
  }
  private func trackChanges() {
    let epoch = generation
    withObservationTracking {
      _ = output.volumes
      _ = output.muteStates
      _ = output.defaultDeviceUID
      _ = output.defaultInputDeviceUID
      _ = output.lastError
      _ = readOutputSelectionFailure()
      _ = input.states
      _ = input.lastError
      _ = systemSounds.outputUID
      _ = systemSounds.lastError
      _ = alertVolume.observedVolume
      _ = alertVolume.requestedVolume
      _ = alertVolume.isApplying
      _ = alertVolume.lastError
      _ = alertSilencing.isSilenced
      _ = alertSilencing.lastError
      _ = bluetooth.pairedDevices
      _ = bluetooth.connectionPhases
      _ = bluetooth.connectionErrors
      _ = bluetooth.isPoweredOn
      _ = bluetooth.lastError
      _ = ddc.states
      _ = ddc.lastError
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.isRunning, self.generation == epoch else { return }
        self.trackChanges()
        self.onChange?()
      }
    }
  }
}
