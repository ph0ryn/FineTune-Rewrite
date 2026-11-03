/// Render values only. This file deliberately imports no HAL, Bluetooth, scripting, or service code.
struct DeviceSystemOutputOption: Equatable, Identifiable, Sendable {
  let uid: String
  let name: String
  var id: String { uid }
}

struct DeviceSettingsPresentation: Equatable, Sendable {
  var systemOutputUID: String?
  var systemOutputOptions: [DeviceSystemOutputOption]
  var canSetSystemOutput: Bool
  var followsDefault: Bool
  var alertVolume: Float?
  var canSetAlertVolume: Bool
  var alertIsApplying: Bool
  var error: String?
  var bluetooth: BluetoothPresentation
}

struct BluetoothPresentation: Equatable, Sendable {
  var isPoweredOn: Bool?
  var paired: [PairedBluetoothPresentation]
  var error: String?
}

enum BluetoothConnectionState: Equatable, Sendable {
  case idle
  case connecting
  case waitingForAudioDevice
  case connected
  case failed
}

struct PairedBluetoothPresentation: Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var iconSymbol: String
  var connectionState: BluetoothConnectionState
  var error: String?
}

/// Required actions. Production assembly supplies effects; a view never invents a success/no-op.
@MainActor
struct DeviceSettingsActions {
  let setSystemOutput: (String) -> Void
  let setSystemFollowDefault: () -> Void
  let setAlertVolume: (Float) -> Void
  let refreshBluetooth: () -> Void
  let connectBluetooth: (String) -> Void
}
