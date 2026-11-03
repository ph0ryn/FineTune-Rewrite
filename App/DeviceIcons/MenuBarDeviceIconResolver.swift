import AppKit
import CoreAudio
import FineTuneDomain
import FineTunePlatform

/// Selects a display glyph from an already observed device snapshot, never from a live HAL read.
enum MenuBarDeviceIconResolver {
  static let fallbackSymbol = TransportType.unknown.defaultIconSymbol

  static func resolveSymbol(
    priorityOrder: [String],
    outputDevices: [AudioDevice],
    defaultDeviceID: AudioDeviceID,
    overrideForUID: (String) -> String? = { _ in nil },
    isSymbolResolvable: (String) -> Bool = {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    },
    isDeviceAvailable: (AudioDevice) -> Bool,
    uidForDefaultID: (AudioDeviceID) -> String? = { _ in nil },
    symbolForDevice: (AudioDevice) -> String = {
      DeviceIconSymbol.iconSymbol(forName: $0.name, transport: .unknown)
    },
    symbolForDefaultID: (AudioDeviceID) -> String
  ) -> String {
    func customSymbol(_ uid: String) -> String? {
      guard let candidate = overrideForUID(uid), isSymbolResolvable(candidate) else { return nil }
      return candidate
    }

    if let current = outputDevices.first(where: { $0.id == defaultDeviceID }),
      isDeviceAvailable(current)
    {
      return customSymbol(current.uid) ?? symbolForDevice(current)
    }
    if let preferred = priorityOrder.lazy.compactMap({ uid in
      outputDevices.last { $0.uid == uid }
    }).first(where: isDeviceAvailable) {
      return customSymbol(preferred.uid) ?? symbolForDevice(preferred)
    }
    guard defaultDeviceID != 0 else { return fallbackSymbol }
    if let uid = uidForDefaultID(defaultDeviceID), let custom = customSymbol(uid) { return custom }
    return symbolForDefaultID(defaultDeviceID)
  }
}
