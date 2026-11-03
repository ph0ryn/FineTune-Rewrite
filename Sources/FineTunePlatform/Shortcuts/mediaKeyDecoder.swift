import FineTuneControl

/// Interprets the HID auxiliary-control bitfield without installing an event tap.
public struct IOKitMediaKeyDecoder: MediaKeyEventDecoding {
  public init() {}

  public func decode(data1: Int) -> MediaKeyEvent? {
    let bits = UInt32(truncatingIfNeeded: data1)
    guard (bits >> 8) & 0xff == 0x0a else { return nil }
    let repeats = bits & 0xff != 0
    switch bits >> 16 {
    case 0: return .volumeUp(isRepeat: repeats)
    case 1: return .volumeDown(isRepeat: repeats)
    case 7: return repeats ? nil : .muteToggle
    default: return nil
    }
  }
}
