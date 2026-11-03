import FineTuneDomain
import Observation

/// The last observed authorization result. Unknown is not treated as permission to capture.
public enum AudioCaptureAuthorizationStatus: Sendable {
  case unknown, authorized, denied
}

@Observable
@MainActor
public final class AudioCaptureAuthorization {
  public var status: AudioCaptureAuthorizationStatus

  public init(status: AudioCaptureAuthorizationStatus = .unknown) { self.status = status }
}

/// An actual in-memory profile cache; loading/importing profiles is a separate adapter responsibility.
@MainActor
public final class AutoEQProfileCache {
  private var profiles: [String: AutoEQProfile]

  public init(profiles: [AutoEQProfile] = []) {
    self.profiles = Dictionary(
      profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
  }

  public func profile(for id: String) -> AutoEQProfile? { profiles[id] }
  public func store(_ profile: AutoEQProfile) { profiles[profile.id] = profile }
  public func remove(id: String) { profiles[id] = nil }
}

public enum DeviceVolumePolicy {
  /// Hardware scalars have a silence floor; software PCM gain must retain small square-law values.
  public static func storedVolume(_ volume: Float, tier: VolumeControlTier) -> Float {
    switch tier {
    case .software: volume
    case .hardware, .ddc: volume < 0.01 ? 0 : volume
    }
  }
}
