// Offscreen AppKit-only test fixtures for AppRenderedTests.
// No Vision OCR, ScreenCaptureKit, private SwiftUI view proxies, or pointer event loops.
import AppKit
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI

@testable import FineTune

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

  var bindings: MixerBindings { MixerBindings(read: { self.snapshot }, actions: actions) }

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

  var interface: MixerProfileInterface {
    MixerProfileInterface(
      read: { _ in self.snapshot },
      search: { _, _ in
        MixerProfileSearchResult(
          entries: [
            MixerProfileChoice(id: "catalog-profile", name: "Headphones", detail: "Measured")
          ],
          totalCount: 1)
      },
      importProfile: { _, _, _ in self.events.append("import") },
      select: { _, _ in self.events.append("select") },
      setFavorite: { self.events.append("favorite:\($0):\($1)") },
      setPreampEnabled: { self.events.append("preamp:\($0)") })
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

@MainActor
func leafDescendants(of view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + leafDescendants(of: $0) }
}
