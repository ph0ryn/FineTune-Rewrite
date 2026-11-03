import FineTuneDomain
import Foundation

public struct DDCAudioCandidate: Equatable, Sendable {
  public let uid: String
  public let name: String
  public let transport: TransportType

  public init(uid: String, name: String, transport: TransportType) {
    self.uid = uid
    self.name = name
    self.transport = transport
  }
}

public struct DDCDisplaySnapshot: Equatable, Identifiable, Sendable {
  /// Ephemeral transport token, never a persisted CoreAudio UID.
  public let id: UUID
  public let name: String?
  public let edid: DDCDisplayEDID?
  public let volume: DDCVCPValue?
  public let error: String?

  public init(
    id: UUID, name: String?, edid: DDCDisplayEDID?, volume: DDCVCPValue?, error: String? = nil
  ) {
    self.id = id
    self.name = name
    self.edid = edid
    self.volume = volume
    self.error = error
  }
}

public protocol DDCDisplayTransport: Sendable {
  func discover() async throws -> [DDCDisplaySnapshot]
  /// Returns actual VCP readback, not the requested value. A successful byte write is insufficient.
  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue
  func readVolume(displayID: UUID) async throws -> DDCVCPValue
  /// Serialized cleanup runs even if its awaiting task is cancelled.
  func close() async throws
}

/// The existing shared preference store is reused directly; no second desired-state mirror is saved.
@MainActor
public protocol DDCPreferenceStoring: AnyObject {
  var lastSaveError: String? { get }
  func getDDCVolume(for deviceUID: String) -> Int?
  func setDDCVolume(for deviceUID: String, to volume: Int)
  func getDDCMuteState(for deviceUID: String) -> Bool
  func setDDCMuteState(for deviceUID: String, to muted: Bool)
  func getDDCSavedVolume(for deviceUID: String) -> Int?
  func setDDCSavedVolume(for deviceUID: String, to volume: Int)
  func flushSync()
}

extension SettingsManager: DDCPreferenceStoring {}
