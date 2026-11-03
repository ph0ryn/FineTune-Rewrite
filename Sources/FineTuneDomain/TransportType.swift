/// A connection classification; resolving OS transport codes is a platform responsibility.
public enum TransportType: String, Sendable, Hashable, CustomStringConvertible {
  case builtIn
  case usb
  case bluetooth
  case bluetoothLE
  case airPlay
  case virtual
  case thunderbolt
  case hdmi
  case displayPort
  case aggregate
  case unknown

  public var description: String { rawValue }
}
