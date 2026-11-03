import Observation

/// Suppresses a duplicate HUD while the app's menu-bar popup is visible.
@MainActor @Observable
final class PopupVisibilityService {
  var isVisible = false
}
