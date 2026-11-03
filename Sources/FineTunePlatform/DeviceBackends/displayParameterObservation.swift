import AppKit
import Foundation

@MainActor
public protocol DisplayParameterObserving {
  func observe(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation
}

public struct SystemDisplayParameterObserver: DisplayParameterObserving {
  public init() {}

  public func observe(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation {
    let center = NotificationCenter.default
    let token = center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in Task { @MainActor in onChange() } }
    return DevicePropertyObservation { center.removeObserver(token) }
  }
}
