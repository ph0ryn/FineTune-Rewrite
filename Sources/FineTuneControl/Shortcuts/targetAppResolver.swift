@MainActor
public protocol TargetAppResolving: AnyObject {
  func resolveTargetBundleID(audibleCandidates: [String]) -> String?
}

/// Target selection owns only application identifiers. Workspace observation is a Platform adapter.
@MainActor
public final class TargetAppResolver: TargetAppResolving {
  private static let audioDaemonBundleIDs: Set<String> = [
    "com.apple.systemsoundserverd", "com.apple.coreaudiod",
  ]

  private let ownBundleID: String
  private let frontmostBundleIDProvider: @MainActor () -> String?
  private var lastExternalFrontmost: String?
  private var lastTarget: String?

  public init(
    ownBundleID: String, frontmostBundleIDProvider: @escaping @MainActor () -> String?
  ) {
    self.ownBundleID = ownBundleID
    self.frontmostBundleIDProvider = frontmostBundleIDProvider
  }

  public func handleActivation(bundleID: String?) {
    if let bundleID, isSelectable(bundleID) { lastExternalFrontmost = bundleID }
  }

  public func resolveTargetBundleID(audibleCandidates: [String]) -> String? {
    let candidates = audibleCandidates.filter { isSelectable($0) }
    let frontmost = frontmostBundleIDProvider().flatMap { isSelectable($0) ? $0 : nil }
    if candidates.isEmpty {
      return frontmost ?? lastExternalFrontmost
    }
    if let frontmost, candidates.contains(frontmost) {
      lastTarget = frontmost
    } else if lastTarget == nil || !candidates.contains(lastTarget!) {
      lastTarget = candidates.first
    }
    return lastTarget
  }

  /// The same eligibility rule applies to activation history, frontmost fallback and audible
  /// candidates, so an unaddressable daemon can never become a volume-control target.
  private func isSelectable(_ bundleID: String) -> Bool {
    bundleID != ownBundleID && !Self.audioDaemonBundleIDs.contains(bundleID)
  }
}

public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
  case togglePopup
  case targetAppVolumeUp = "frontmostAppVolumeUp"
  case targetAppVolumeDown = "frontmostAppVolumeDown"
  case targetAppMuteToggle = "frontmostAppMuteToggle"

  public var supportsRepeat: Bool {
    self == .targetAppVolumeUp || self == .targetAppVolumeDown
  }

  public var displayName: String {
    switch self {
    case .togglePopup: "Toggle FineTune Popup"
    case .targetAppVolumeUp: "App Volume Up"
    case .targetAppVolumeDown: "App Volume Down"
    case .targetAppMuteToggle: "App Mute"
    }
  }

  public var stableID: String {
    switch self {
    case .togglePopup: "toggle-popup"
    case .targetAppVolumeUp: "frontmost-app-volume-up"
    case .targetAppVolumeDown: "frontmost-app-volume-down"
    case .targetAppMuteToggle: "frontmost-app-mute-toggle"
    }
  }
}
