import FineTuneDomain
import Foundation

struct DDCDeviceMatches {
  var bindings: [String: UUID] = [:]
  var unavailable: [String: any Error] = [:]
}

enum DDCVolumeScale {
  static func percent(of value: DDCVCPValue) throws -> Int {
    guard value.current <= value.maximum else { throw DDCPacketError.invalidResponse }
    // The fixed source uses VCP 0x62 as 0...100. Unknown scales are not guessed or clamped.
    guard value.maximum == 100 else {
      throw DeviceBackendError.unsupported("Non-percentage DDC speaker volume")
    }
    return Int(value.current)
  }
}

/// Conservative evidence matching only: both endpoint degrees must be one.
/// This isolates the fixed-source name/EDID heuristic; it is not an OS physical-identity guarantee.
enum DDCDeviceMatcher {
  static func match(candidates: [DDCAudioCandidate], displays: [DDCDisplaySnapshot])
    -> DDCDeviceMatches
  {
    var result = DDCDeviceMatches()
    var edges: [String: Set<UUID>] = [:]
    var reverse: [UUID: Set<String>] = [:]
    for candidate in candidates where eligible(candidate.transport) {
      let matches = Set(displays.filter { hasEvidence(candidate, $0) }.map(\.id))
      edges[candidate.uid] = matches
      for displayID in matches { reverse[displayID, default: []].insert(candidate.uid) }
    }
    let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    for candidate in candidates {
      guard let matches = edges[candidate.uid], !matches.isEmpty else {
        result.unavailable[candidate.uid] = DeviceBackendError.unsupported(
          "An identifiable DDC display for \(candidate.name)")
        continue
      }
      guard matches.count == 1, let displayID = matches.first, reverse[displayID]?.count == 1 else {
        result.unavailable[candidate.uid] = DeviceBackendError.ambiguousDisplay(candidate.uid)
        continue
      }
      guard let display = byID[displayID], let volume = display.volume else {
        result.unavailable[candidate.uid] = DeviceBackendError.operationFailed(
          byID[displayID]?.error ?? "The display's DDC speaker volume is unavailable.")
        continue
      }
      do {
        _ = try DDCVolumeScale.percent(of: volume)
        result.bindings[candidate.uid] = displayID
      } catch {
        result.unavailable[candidate.uid] = error
      }
    }
    return result
  }

  static func eligible(_ transport: TransportType) -> Bool {
    switch transport {
    case .hdmi, .displayPort, .usb, .thunderbolt: true
    default: false
    }
  }

  private static func hasEvidence(_ audio: DDCAudioCandidate, _ display: DDCDisplaySnapshot) -> Bool
  {
    let prefix = encodedPrefix(audio)
    if let prefix, let edid = display.edid, prefix != edid.encodedUIDPrefix { return false }
    let matchesEDID = prefix != nil && prefix == display.edid?.encodedUIDPrefix
    let audioName = audio.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let displayName = display.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let matchesName: Bool
    if let displayName, !displayName.isEmpty, !audioName.isEmpty {
      matchesName = audioName.contains(displayName) || displayName.contains(audioName)
    } else {
      matchesName = false
    }
    return matchesEDID || matchesName
  }

  private static func encodedPrefix(_ audio: DDCAudioCandidate) -> String? {
    guard audio.transport == .hdmi || audio.transport == .displayPort,
      audio.uid.count >= 9, audio.uid.dropFirst(8).first == "-"
    else { return nil }
    let prefix = String(audio.uid.prefix(8))
    let hexadecimal = Set("0123456789abcdefABCDEF")
    guard prefix.allSatisfy({ hexadecimal.contains($0) }) else { return nil }
    return prefix.lowercased()
  }
}
