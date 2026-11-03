import AudioToolbox
import Foundation

/// Presentation snapshot. Reading or changing a HAL device belongs to the Platform adapter.
struct DeviceInspectorInfo: Equatable, Sendable {
  let transportLabel: String
  let sampleRate: Double
  let availableSampleRates: [Double]
  let sampleRateSettable: Bool
  let formatLabel: String?
  let hogModeOwner: pid_t
  let uid: String

  static func formatSampleRate(_ rate: Double) -> String {
    guard rate > 0 else { return "—" }
    let kilohertz = rate / 1000
    return String(
      format: kilohertz.rounded(.down) == kilohertz ? "%.0f kHz" : "%.1f kHz", kilohertz)
  }

  static func formatPhysicalFormat(_ format: AudioStreamBasicDescription?) -> String? {
    guard let format, format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel > 0 else {
      return nil
    }
    return "\(format.mBitsPerChannel)-bit PCM"
  }

  static func formatHogModeOwner(_ owner: pid_t, processName: String?) -> String? {
    guard owner > 0, owner != getpid() else { return nil }
    let identity =
      processName.flatMap { $0.isEmpty ? nil : $0 }
      .map { "\($0) (PID \(owner))" } ?? "PID \(owner)"
    return "In exclusive use by \(identity)"
  }
}

struct InfoGridLayout: Equatable {
  enum Row: Equatable {
    case transport(String)
    case sampleRate(display: String, isPicker: Bool, options: [Double])
    case format(String)
    case deviceID(String)
  }

  let rows: [Row]

  init(info: DeviceInspectorInfo) {
    let editable = info.sampleRateSettable && info.availableSampleRates.count > 1
    var result: [Row] = [
      .transport(info.transportLabel),
      .sampleRate(
        display: DeviceInspectorInfo.formatSampleRate(info.sampleRate), isPicker: editable,
        options: editable ? info.availableSampleRates : []
      ),
    ]
    if let format = info.formatLabel { result.append(.format(format)) }
    result.append(.deviceID(info.uid))
    rows = result
  }
}
