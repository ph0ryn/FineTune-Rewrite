import ApplicationServices
import FineTuneControl

/// Reads Accessibility authorization without prompting or changing it.
@MainActor
public final class SystemAccessibilityTrust: AccessibilityTrustProviding {
  public private(set) var isTrusted: Bool

  public init() { isTrusted = AXIsProcessTrusted() }

  public func refresh() { isTrusted = AXIsProcessTrusted() }
}
