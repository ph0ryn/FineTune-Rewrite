import Observation

/// Presentation state, distinct from the user's saved media-key preference.
@MainActor @Observable
final class MediaKeyStatus {
  var isOffline = false
  var suppressionDegraded = false
}
