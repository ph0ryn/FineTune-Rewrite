import AppKit
import FineTuneDomain
import FineTunePlatform
import SwiftUI

/// Presentation-only direction. Device identity remains the observed persistent UID.
enum MixerDeviceScope: String, CaseIterable, Identifiable {
  case output, input
  var id: Self { self }
  var title: String { self == .output ? "Output" : "Input" }
}

/// A render value, never a second runtime or persistence store.
struct MixerAppPresentation: Identifiable {
  var id: String
  var name: String
  var icon: NSImage?
  var isActive: Bool
  var gain: Float
  var isMuted: Bool
  var boost: BoostLevel
  var selectionMode: DeviceSelectionMode
  var isFollowingDefault: Bool
  var selectedDeviceUIDs: Set<String>
  var eqSettings: EQSettings
  var isPinned: Bool
  var isIgnored: Bool
  var routeStatus: String?
  /// Native's observed post-output peak; nil means no current telemetry, not silence.
  var peakLevel: Float? = nil
}

struct MixerDevicePresentation: Identifiable {
  var device: AudioDevice
  var transport: TransportType
  var isDefault: Bool
  var volume: Float?
  var isMuted: Bool?
  var backend: VolumeControlTier
  var automaticBackend: VolumeControlTier?
  var isHidden: Bool
  var iconOverride: String?
  var volumeOverride: VolumeControlTier?
  var canSetVolume: Bool
  var canSetMute: Bool
  var error: String?
  var id: String { device.uid }

  func automaticSymbol(scope: MixerDeviceScope) -> String {
    scope == .input
      ? DeviceIconSymbol.inputSymbol(forName: device.name, transport: transport)
      : DeviceIconSymbol.iconSymbol(forName: device.name, transport: transport)
  }
}

/// A diagnostic projected from real probe/authorization state, never an enabled/granted boolean.
struct MixerCaptureNotice {
  enum Action { case requestPermission, openSettings }
  let message: String
  let action: Action?
}

struct MixerSnapshot {
  var apps: [MixerAppPresentation]
  var outputDevices: [MixerDevicePresentation]
  var inputDevices: [MixerDevicePresentation]
  var settings: AppSettings
  var userPresets: [UserEQPreset]
  var error: String?
  var backend: DeviceSettingsPresentation
  var captureNotice: MixerCaptureNotice?
}

/// Every effect must be supplied by the composition root. No callback has a no-op default.
@MainActor
struct MixerAppActions {
  /// A UI edit intent: the common Control operation also unmutes, retaining the independent boost.
  let setVolume: (String, Float) -> Void
  let setMute: (String, Bool) -> Void
  let setBoost: (String, BoostLevel) -> Void
  let followDefault: (String) -> Void
  let setRoute: (String, DeviceSelectionMode, Set<String>) -> Void
  let setPinned: (String, Bool) -> Void
  let setIgnored: (String, Bool) -> Void
  let setEQ: (String, EQSettings) -> Void
  let stepVolume: (String, Bool, Bool) -> Void
  let createPreset: (String, EQSettings) -> Void
  let renamePreset: (UUID, String) -> Void
  let deletePreset: (UUID) -> Void
  let activate: (String) -> Void
}

@MainActor
struct MixerDeviceActions {
  let setDefault: (MixerDeviceScope, String) -> Void
  let setVolume: (MixerDeviceScope, String, Float) -> Void
  let setMute: (MixerDeviceScope, String, Bool) -> Void
  let setHidden: (MixerDeviceScope, String, Bool) -> Void
  /// Connected order only; merging disconnected saved preferences belongs to Control/store.
  let setPriority: (MixerDeviceScope, [String]) -> Void
  let setIcon: (String, String?) -> Void
  let setVolumeOverride: (String, VolumeControlTier?) -> Void
  let stepVolume: (MixerDeviceScope, String, Bool, Bool) -> Void
}

@MainActor
struct MixerActions {
  let app: MixerAppActions
  let device: MixerDeviceActions
  let openSettings: () -> Void
  let close: () -> Void
  let backend: DeviceSettingsActions
  let requestCapturePermission: () -> Void
  let openCaptureSettings: () -> Void
}

/// The actual view bindings. They read fresh values and forward requests, without retaining edits.
@MainActor
struct MixerBindings {
  let read: () -> MixerSnapshot
  let actions: MixerActions

  func current(_ app: MixerAppPresentation) -> MixerAppPresentation {
    read().apps.first { $0.id == app.id } ?? app
  }

  func current(_ device: MixerDevicePresentation, scope: MixerDeviceScope)
    -> MixerDevicePresentation
  {
    let rows = scope == .output ? read().outputDevices : read().inputDevices
    return rows.first { $0.id == device.id } ?? device
  }

  func visibleApps(editing: Bool) -> [MixerAppPresentation] {
    read().apps.filter { editing || (!$0.isIgnored && ($0.isActive || $0.isPinned)) }
  }

  func devices(scope: MixerDeviceScope, editing: Bool) -> [MixerDevicePresentation] {
    let all = scope == .output ? read().outputDevices : read().inputDevices
    let visible = all.filter { $0.isDefault || !$0.isHidden }
    return editing || visible.isEmpty ? all : visible
  }

  func appVolume(_ app: MixerAppPresentation) -> Binding<Double> {
    Binding(
      get: { VolumeMapping.gainToSlider(current(app).gain) },
      set: { actions.app.setVolume(app.id, VolumeMapping.sliderToGain($0)) }
    )
  }

  func appMute(_ app: MixerAppPresentation) -> Binding<Bool> {
    Binding(get: { current(app).isMuted }, set: { actions.app.setMute(app.id, $0) })
  }

  func appBoost(_ app: MixerAppPresentation) -> Binding<BoostLevel> {
    Binding(get: { current(app).boost }, set: { actions.app.setBoost(app.id, $0) })
  }

  /// Root and unit tests construct this same real component. DeviceRow owns its only slider mapping.
  func deviceRow(
    _ row: MixerDevicePresentation, scope: MixerDeviceScope, autoEQSubtitle: String? = nil
  ) -> DeviceRow {
    let device = AudioDevice(
      id: row.device.id, uid: row.id, name: row.device.name,
      icon: deviceIcon(row, scope: scope), supportsAutoEQ: row.device.supportsAutoEQ)
    return DeviceRow(
      device: device, isDefault: row.isDefault, volume: row.volume, isMuted: row.isMuted,
      volumeBackend: row.backend, canSetVolume: row.canSetVolume, canSetMute: row.canSetMute,
      isInput: scope == .input,
      onSetDefault: { actions.device.setDefault(scope, row.id) },
      onVolumeChange: { actions.device.setVolume(scope, row.id, $0) },
      onMuteToggle: { toggleDeviceMute(scope: scope, uid: row.id) },
      autoEQSubtitle: autoEQSubtitle)
  }

  func deviceIcon(_ row: MixerDevicePresentation, scope: MixerDeviceScope) -> NSImage? {
    let automatic =
      row.device.icon
      ?? NSImage(systemSymbolName: row.automaticSymbol(scope: scope), accessibilityDescription: nil)
    return DeviceIconResolver.displayIcon(
      overrideSymbol: row.iconOverride, automatic: automatic, deviceName: row.device.name)
  }

  /// Mouse and keyboard resolve the current UID's same UI intent; no stale row supplies mute state.
  func toggleDeviceMute(scope: MixerDeviceScope, uid: String) {
    let rows = scope == .output ? read().outputDevices : read().inputDevices
    guard let row = rows.first(where: { $0.id == uid }),
      let intent = DeviceRow.muteToggleIntent(
        volume: row.volume, isMuted: row.isMuted,
        backend: scope == .input ? .hardware : row.backend,
        canSetVolume: row.canSetVolume, canSetMute: row.canSetMute)
    else { return }
    switch intent {
    case .setVolume(let gain): actions.device.setVolume(scope, uid, gain)
    case .setMuted(let muted): actions.device.setMute(scope, uid, muted)
    }
  }

  func eqEnabled(_ app: MixerAppPresentation) -> Binding<Bool> {
    Binding(
      get: { current(app).eqSettings.isEnabled },
      set: { value in
        var settings = current(app).eqSettings
        settings.isEnabled = value
        actions.app.setEQ(app.id, settings)
      }
    )
  }

  func eqBand(_ app: MixerAppPresentation, index: Int) -> Binding<Double> {
    precondition((0..<EQSettings.bandCount).contains(index))
    return Binding(
      get: { Double(current(app).eqSettings.bandGains[index]) },
      set: { value in
        var settings = current(app).eqSettings
        settings.bandGains[index] = Float(
          max(Double(EQSettings.minGainDB), min(Double(EQSettings.maxGainDB), value)))
        actions.app.setEQ(app.id, settings)
      }
    )
  }

  func applyPreset(_ preset: EQPreset, to app: MixerAppPresentation) {
    applyCurve(preset.settings, to: app)
  }

  func applyCurve(_ curve: EQSettings, to app: MixerAppPresentation) {
    var next = curve
    next.isEnabled = current(app).eqSettings.isEnabled
    actions.app.setEQ(app.id, next)
  }

  func followDefault(_ app: MixerAppPresentation) { actions.app.followDefault(app.id) }

  func selectRoute(_ app: MixerAppPresentation, mode: DeviceSelectionMode, uids: Set<String>) {
    actions.app.setRoute(app.id, mode, uids)
  }

  func routeLabel(_ app: MixerAppPresentation) -> String {
    if app.isFollowingDefault { return "System Default" }
    let devices = read().outputDevices
    let names = app.selectedDeviceUIDs.sorted().map { uid in
      devices.first { $0.id == uid }?.device.name ?? "Unavailable (\(uid))"
    }
    let outputs = names.isEmpty ? "No output selected" : names.joined(separator: ", ")
    if app.selectionMode == .multi {
      return "Multi · \(names.count) \(names.count == 1 ? "device" : "devices") — \(outputs)"
    }
    return outputs
  }
}
