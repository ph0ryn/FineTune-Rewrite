// Minimal value snapshots and action-recording test doubles for the no-render presentation
// contracts. They construct no runtime, service, application, window, hosting view, bitmap, event
// or loop, and create no NSImage.
import FineTuneDomain
import Foundation
import Observation
import SwiftUI
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
    MixerBindings(snapshot: snapshot, actions: Self.failingActions, readFresh: { snapshot })
  }

  static func app(
    id: String,
    name: String,
    isActive: Bool = true,
    selectionMode: DeviceSelectionMode = .single,
    selectedDeviceUIDs: Set<String> = [],
    isPinned: Bool = false,
    isIgnored: Bool = false,
    isFollowingDefault: Bool = false,
    routeStatus: String? = nil
  ) -> MixerAppPresentation {
    MixerAppPresentation(
      id: id, name: name, icon: nil, isActive: isActive, gain: 0.5, isMuted: false,
      boost: .x1, selectionMode: selectionMode, isFollowingDefault: isFollowingDefault,
      selectedDeviceUIDs: selectedDeviceUIDs, eqSettings: .flat, isPinned: isPinned,
      isIgnored: isIgnored, routeStatus: routeStatus)
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

@MainActor
@Observable
final class MixerTestSource {
  var snapshot: MixerSnapshot
  let profileSource = MixerProfileTestSource()
  var events: [String] = []
  var lastAppID: String?
  var lastDeviceUID: String?
  var lastDeviceScope: MixerDeviceScope?
  var lastGain: Float?
  var lastBool: Bool?
  var lastBoost: BoostLevel?
  var lastEQ: EQSettings?
  var lastMode: DeviceSelectionMode?
  var lastUIDs: Set<String>?

  init() {
    let output = AudioDevice(
      id: 101, uid: "output-uid", name: "Output", icon: nil, supportsAutoEQ: true)
    let input = AudioDevice(
      id: 102, uid: "input-uid", name: "Input", icon: nil, supportsAutoEQ: false)
    snapshot = MixerSnapshot(
      apps: [
        MixerAppPresentation(
          id: "com.example.player", name: "Player", icon: nil, isActive: false,
          gain: 0.25, isMuted: false, boost: .x1, selectionMode: .single,
          isFollowingDefault: true, selectedDeviceUIDs: [], eqSettings: .flat,
          isPinned: true, isIgnored: false, routeStatus: nil
        )
      ],
      outputDevices: [
        MixerDevicePresentation(
          device: output, transport: .usb, isDefault: true, volume: 0.25, isMuted: false,
          backend: .software, automaticBackend: .software, isHidden: false,
          iconOverride: nil, volumeOverride: nil, canSetVolume: true, canSetMute: true, error: nil
        )
      ],
      inputDevices: [
        MixerDevicePresentation(
          device: input, transport: .usb, isDefault: true, volume: 0.25, isMuted: false,
          backend: .hardware, automaticBackend: .hardware, isHidden: false,
          iconOverride: nil, volumeOverride: nil, canSetVolume: true, canSetMute: true, error: nil
        )
      ], settings: .init(), userPresets: [], error: nil, backend: testDeviceSettings(),
      captureNotice: nil
    )
  }

  var bindings: MixerBindings {
    MixerBindings(snapshot: snapshot, actions: actions, readFresh: { self.snapshot })
  }

  var actions: MixerActions {
    MixerActions(
      app: MixerAppActions(
        setVolume: {
          self.lastAppID = $0
          self.lastGain = $1
          self.events.append("app-volume")
        },
        setMute: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("app-mute")
        },
        setBoost: {
          self.lastAppID = $0
          self.lastBoost = $1
          self.events.append("app-boost")
        },
        followDefault: {
          self.lastAppID = $0
          self.events.append("follow-default")
        },
        setRoute: {
          self.lastAppID = $0
          self.lastMode = $1
          self.lastUIDs = $2
          self.events.append("route")
        },
        setPinned: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("pin")
        },
        setIgnored: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("ignore")
        },
        setEQ: {
          self.lastAppID = $0
          self.lastEQ = $1
          self.events.append("eq")
        },
        stepVolume: {
          self.lastAppID = $0
          self.events.append("app-step:\($1):\($2)")
        },
        createPreset: { self.events.append("create-preset:\($0):\($1.bandGains.count)") },
        renamePreset: { self.events.append("rename-preset:\($0):\($1)") },
        deletePreset: { self.events.append("delete-preset:\($0)") },
        activate: {
          self.lastAppID = $0
          self.events.append("activate")
        }
      ),
      device: MixerDeviceActions(
        setDefault: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.events.append("default")
        },
        setVolume: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.lastGain = $2
          self.events.append("device-volume")
        },
        setMute: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.lastBool = $2
          self.events.append("device-mute")
        },
        setHidden: { self.events.append("hidden:\($0):\($1):\($2)") },
        setPriority: { self.events.append("priority:\($0):\($1.joined(separator: ","))") },
        setIcon: { self.events.append("icon:\($0):\($1 ?? "automatic")") },
        setVolumeOverride: { self.events.append("override:\($0):\(String(describing: $1))") },
        stepVolume: { self.events.append("device-step:\($0):\($1):\($2):\($3)") }
      ),
      openSettings: { self.events.append("settings") }, close: { self.events.append("close") },
      backend: recordingDeviceSettingsActions { self.events.append($0) },
      requestCapturePermission: { self.events.append("capture-request") },
      openCaptureSettings: { self.events.append("capture-settings") }
    )
  }
}

@MainActor
@Observable
final class MixerProfileTestSource {
  var snapshot = MixerProfilePresentation(
    catalogState: .ready, selection: nil, profileName: nil, isMissing: false,
    isResolving: false, selectionError: nil, favoriteIDs: [], preampEnabled: true)
  var events: [String] = []
  var lastDeviceUID: String?
  var lastSelection: AutoEQSelection?
  var lastQuery: String?
  var lastFavoritesOnly: Bool?
  var lastImportURL: URL?
  var lastImportName: String?

  var interface: MixerProfileInterface {
    MixerProfileInterface(
      read: { _ in self.snapshot },
      search: {
        self.lastQuery = $0
        self.lastFavoritesOnly = $1
        return MixerProfileSearchResult(
          entries: [
            MixerProfileChoice(id: "catalog-profile", name: "Headphones", detail: "Measured")
          ],
          totalCount: 1)
      },
      importProfile: {
        self.lastDeviceUID = $0
        self.lastImportURL = $1
        self.lastImportName = $2
        self.events.append("import")
      },
      select: {
        self.lastDeviceUID = $0
        self.lastSelection = $1
        self.events.append("select")
      },
      setFavorite: { self.events.append("favorite:\($0):\($1)") },
      setPreampEnabled: { self.events.append("preamp:\($0)") })
  }
}

@MainActor
@Observable
final class SettingsTestSource {
  var snapshot = SettingsSnapshot(
    settings: AppSettings(), isAccessibilityTrusted: false, isMediaKeyOffline: false, error: nil,
    device: testDeviceSettings())
  var events: [String] = []
  var lastShortcutAction: ShortcutAction?
  var lastShortcut: ShortcutCodable?

  var bindings: SettingsBindings { SettingsBindings(read: { self.snapshot }, actions: actions) }

  var actions: SettingsActions {
    SettingsActions(
      updateSettings: {
        self.snapshot.settings = $0
        self.events.append("settings")
      },
      recordShortcut: {
        self.lastShortcutAction = $0
        self.lastShortcut = $1
        self.events.append("shortcut")
      },
      requestAccessibility: { self.events.append("accessibility") },
      retryMediaKeys: { self.events.append("retry-keys") },
      resetAll: { self.events.append("reset") },
      device: recordingDeviceSettingsActions { self.events.append($0) }
    )
  }
}

func testDeviceSettings() -> DeviceSettingsPresentation {
  DeviceSettingsPresentation(
    systemOutputUID: nil, systemOutputOptions: [], canSetSystemOutput: false, followsDefault: true,
    alertVolume: nil, canSetAlertVolume: false, alertIsApplying: false,
    alertVolumeSilenced: false, error: nil,
    bluetooth: BluetoothPresentation(isPoweredOn: nil, paired: [], error: nil))
}

@MainActor
func recordingDeviceSettingsActions(_ record: @escaping (String) -> Void) -> DeviceSettingsActions {
  DeviceSettingsActions(
    setSystemOutput: { record("system-output:\($0)") },
    setSystemFollowDefault: { record("system-follow") },
    setAlertVolume: { record("alert:\($0)") },
    refreshBluetooth: { record("bluetooth-refresh") },
    connectBluetooth: { record("bluetooth-connect:\($0)") })
}
