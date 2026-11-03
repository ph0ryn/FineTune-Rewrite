import FineTuneControl

extension SettingsManager: AudioControlSettingsStore {
  public func setAppPinned(
    _ identifier: String, pinned: Bool, displayName: String?, bundleID: String?
  ) throws {
    if pinned {
      pinApp(
        identifier,
        info: try retainedAppInfo(identifier, displayName: displayName, bundleID: bundleID))
    } else {
      unpinApp(identifier)
    }
  }

  public func setAppIgnored(
    _ identifier: String, ignored: Bool, displayName: String?, bundleID: String?
  ) throws {
    if ignored {
      ignoreApp(
        identifier,
        info: try retainedAppInfo(identifier, displayName: displayName, bundleID: bundleID))
    } else {
      unignoreApp(identifier)
    }
  }

  public func setAutoEQFavorite(profileID: String, favorite: Bool) {
    if favorite {
      favoriteAutoEQProfile(id: profileID)
    } else {
      unfavoriteAutoEQProfile(id: profileID)
    }
  }

  private func retainedAppInfo(
    _ identifier: String, displayName: String?, bundleID: String?
  ) throws -> SavedAppInfo {
    if let displayName {
      return SavedAppInfo(
        persistenceIdentifier: identifier, displayName: displayName, bundleID: bundleID)
    }
    if let saved = (getPinnedAppInfo() + getIgnoredAppInfo()).first(where: {
      $0.persistenceIdentifier == identifier
    }) {
      return saved
    }
    throw AudioRouteFailure(
      kind: .unavailable, stage: "saved-app-metadata",
      message: "No metadata is available for \(identifier).")
  }
}
