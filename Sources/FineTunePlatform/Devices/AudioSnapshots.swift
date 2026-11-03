import AppKit
import AudioToolbox
import FineTuneDomain

/// A read-only OS snapshot. Persistent identity is the UID, not the transient HAL object ID.
public struct AudioDevice: Identifiable, Hashable {
  public let id: AudioDeviceID
  public let uid: String
  public let name: String
  public let icon: NSImage?
  public let supportsAutoEQ: Bool

  public init(
    id: AudioDeviceID, uid: String, name: String, icon: NSImage?, supportsAutoEQ: Bool
  ) {
    self.id = id
    self.uid = uid
    self.name = name
    self.icon = icon
    self.supportsAutoEQ = supportsAutoEQ
  }

  public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool { lhs.uid == rhs.uid }

  public func hash(into hasher: inout Hasher) { hasher.combine(uid) }
}

/// OS process objects stay in Platform; Control operates on the process number and saved identifier.
public struct AudioApp: Identifiable, Hashable {
  public let id: pid_t
  public let processObjectIDs: [AudioObjectID]
  public let name: String
  public let icon: NSImage
  public let bundleID: String?
  public let isHelperBacked: Bool

  public init(
    id: pid_t, processObjectIDs: [AudioObjectID], name: String, icon: NSImage,
    bundleID: String?, isHelperBacked: Bool = false
  ) {
    self.id = id
    self.processObjectIDs = processObjectIDs
    self.name = name
    self.icon = icon
    self.bundleID = bundleID
    self.isHelperBacked = isHelperBacked
  }

  public var persistenceIdentifier: String { bundleID ?? "name:\(name)" }

  public static func == (lhs: AudioApp, rhs: AudioApp) -> Bool { lhs.id == rhs.id }

  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension TransportType {
  public init(rawValue: UInt32) {
    switch rawValue {
    case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
    case kAudioDeviceTransportTypeUSB: self = .usb
    case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
    case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
    case kAudioDeviceTransportTypeAirPlay: self = .airPlay
    case kAudioDeviceTransportTypeVirtual: self = .virtual
    case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
    case kAudioDeviceTransportTypeHDMI: self = .hdmi
    case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
    case kAudioDeviceTransportTypeAggregate: self = .aggregate
    default: self = .unknown
    }
  }
}

extension AudioObjectID {
  public static let unknown = AudioObjectID(kAudioObjectUnknown)
  public static let system = AudioObjectID(kAudioObjectSystemObject)
  public var isValid: Bool { self != Self.unknown }
}
