import AppKit
import FineTuneControl

/// Supplies OS activation observations to the OS-independent selection policy.
@MainActor
public final class WorkspaceTargetObservation {
  private let resolver: TargetAppResolver
  private var observation: NSObjectProtocol?

  public init(resolver: TargetAppResolver) { self.resolver = resolver }

  public func start() {
    guard observation == nil else { return }
    observation = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let bundleID =
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .bundleIdentifier
      MainActor.assumeIsolated { self?.resolver.handleActivation(bundleID: bundleID) }
    }
  }

  public func stop() {
    if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
    observation = nil
  }

  isolated deinit {
    if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
  }
}
