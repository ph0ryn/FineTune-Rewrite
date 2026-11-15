// Minimal value snapshot for the no-render mixer contracts. It constructs no runtime, service,
// application, window, hosting view, bitmap, event or loop, and creates no NSImage. Every supplied
// action reports a test failure because these pure projections must never request an effect.
import FineTuneDomain
import Testing

@testable import FineTune

@MainActor
struct MixerContractFixture {
  var snapshot: MixerSnapshot

  init(
    apps: [MixerAppPresentation] = [],
    outputDevices: [MixerDevicePresentation] = [],
    inputDevices: [MixerDevicePresentation] = [],
    captureNotice: MixerCaptureNotice? = nil
  ) {
    snapshot = MixerSnapshot(
      apps: apps,
      outputDevices: outputDevices,
      inputDevices: inputDevices,
      settings: AppSettings(),
      userPresets: [],
      error: nil,
      backend: DeviceSettingsPresentation(
        systemOutputUID: nil, systemOutputOptions: [], canSetSystemOutput: false,
        followsDefault: true, alertVolume: nil, canSetAlertVolume: false, alertIsApplying: false,
        alertVolumeSilenced: false, error: nil,
        bluetooth: BluetoothPresentation(isPoweredOn: nil, paired: [], error: nil)),
      captureNotice: captureNotice)
  }

  var bindings: MixerBindings {
    MixerBindings(read: { snapshot }, actions: Self.failingActions)
  }

  static func app(
    id: String,
    name: String,
    isActive: Bool = true,
    selectionMode: DeviceSelectionMode = .single,
    selectedDeviceUIDs: Set<String> = [],
    isPinned: Bool = false,
    isIgnored: Bool = false,
    isFollowingDefault: Bool = false
  ) -> MixerAppPresentation {
    MixerAppPresentation(
      id: id, name: name, icon: nil, isActive: isActive, gain: 0.5, isMuted: false,
      boost: .x1, selectionMode: selectionMode, isFollowingDefault: isFollowingDefault,
      selectedDeviceUIDs: selectedDeviceUIDs, eqSettings: .flat, isPinned: isPinned,
      isIgnored: isIgnored, routeStatus: nil)
  }

  static func device(
    uid: String,
    name: String,
    isDefault: Bool = false
  ) -> MixerDevicePresentation {
    MixerDevicePresentation(
      device: AudioDevice(id: 0, uid: uid, name: name, icon: nil, supportsAutoEQ: false),
      transport: .usb, isDefault: isDefault, volume: nil, isMuted: nil, backend: .software,
      automaticBackend: .software, isHidden: false, iconOverride: nil, volumeOverride: nil,
      canSetVolume: false, canSetMute: false, error: nil)
  }

  private static var failingActions: MixerActions {
    func fail(_ effect: String) {
      Issue.record("Unexpected effect during a pure projection: \(effect)")
    }
    return MixerActions(
      app: MixerAppActions(
        setVolume: { _, _ in fail("app.setVolume") },
        setMute: { _, _ in fail("app.setMute") },
        setBoost: { _, _ in fail("app.setBoost") },
        followDefault: { _ in fail("app.followDefault") },
        setRoute: { _, _, _ in fail("app.setRoute") },
        setPinned: { _, _ in fail("app.setPinned") },
        setIgnored: { _, _ in fail("app.setIgnored") },
        setEQ: { _, _ in fail("app.setEQ") },
        stepVolume: { _, _, _ in fail("app.stepVolume") },
        createPreset: { _, _ in fail("app.createPreset") },
        renamePreset: { _, _ in fail("app.renamePreset") },
        deletePreset: { _ in fail("app.deletePreset") },
        activate: { _ in fail("app.activate") }),
      device: MixerDeviceActions(
        setDefault: { _, _ in fail("device.setDefault") },
        setVolume: { _, _, _ in fail("device.setVolume") },
        setMute: { _, _, _ in fail("device.setMute") },
        setHidden: { _, _, _ in fail("device.setHidden") },
        setPriority: { _, _ in fail("device.setPriority") },
        setIcon: { _, _ in fail("device.setIcon") },
        setVolumeOverride: { _, _ in fail("device.setVolumeOverride") },
        stepVolume: { _, _, _, _ in fail("device.stepVolume") }),
      openSettings: { fail("openSettings") },
      close: { fail("close") },
      backend: DeviceSettingsActions(
        setSystemOutput: { _ in fail("backend.setSystemOutput") },
        setSystemFollowDefault: { fail("backend.setSystemFollowDefault") },
        setAlertVolume: { _ in fail("backend.setAlertVolume") },
        refreshBluetooth: { fail("backend.refreshBluetooth") },
        connectBluetooth: { _ in fail("backend.connectBluetooth") }),
      requestCapturePermission: { fail("requestCapturePermission") },
      openCaptureSettings: { fail("openCaptureSettings") })
  }
}
