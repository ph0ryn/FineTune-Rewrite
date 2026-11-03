import FineTuneDomain

/// Read-only selection/favorite values from the one saved-settings owner.
@MainActor
public protocol AutoEQPreferencesReading: AnyObject {
  func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection?
  var favoriteAutoEQProfileIDs: Set<String> { get }
  var autoEQPreampEnabled: Bool { get }
}
