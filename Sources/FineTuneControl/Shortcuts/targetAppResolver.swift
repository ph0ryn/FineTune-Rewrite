@MainActor
public protocol TargetAppResolving: AnyObject {
  func resolveTargetBundleID(audibleCandidates: [String]) -> String?
}

/// Target selection owns only application identifiers. Workspace observation is a Platform adapter.
@MainActor
public final class TargetAppResolver: TargetAppResolving {
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
    if let bundleID, bundleID != ownBundleID { lastExternalFrontmost = bundleID }
  }

  public func resolveTargetBundleID(audibleCandidates: [String]) -> String? {
    let candidates = audibleCandidates.filter {
      $0 != ownBundleID && $0 != "com.apple.systemsoundserverd" && $0 != "com.apple.coreaudiod"
    }
    let frontmost = frontmostBundleIDProvider()
    if candidates.isEmpty {
      return frontmost.flatMap { $0 == ownBundleID ? nil : $0 } ?? lastExternalFrontmost
    }
    if let frontmost, candidates.contains(frontmost) {
      lastTarget = frontmost
    } else if lastTarget == nil || !candidates.contains(lastTarget!) {
      lastTarget = candidates.first
    }
    return lastTarget
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
