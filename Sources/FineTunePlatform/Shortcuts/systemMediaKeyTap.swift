import AppKit
import CoreGraphics

/// The lifecycle seam lets tests exercise install/stop/re-enable without OS interception.
@MainActor
public protocol MediaKeyTapInstalling: AnyObject {
  func install(
    onData: @escaping @MainActor (Int, Bool, Bool) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> Bool
  func enable()
  /// Returns whether an installed run-loop source was removed.
  @discardableResult func stop() -> Bool
}

/// Owns only the macOS tap and its run-loop source. Installing never requests permission.
@MainActor
public final class SystemMediaKeyTap: MediaKeyTapInstalling {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var onData: (@MainActor (Int, Bool, Bool) -> Bool)?
  private var onDisabled: (@MainActor () -> Void)?

  public init() {}

  public func install(
    onData: @escaping @MainActor (Int, Bool, Bool) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> Bool {
    if tap != nil { return true }
    guard
      let port = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << 14), callback: systemMediaKeyCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { return false }
    guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0) else {
      CFMachPortInvalidate(port)
      return false
    }
    self.onData = onData
    self.onDisabled = onDisabled
    tap = port
    source = runLoopSource
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    return true
  }

  public func enable() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  }

  @discardableResult
  public func stop() -> Bool {
    let removedSource = source != nil
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
    source = nil
    tap = nil
    onData = nil
    onDisabled = nil
    return removedSource
  }

  fileprivate func receive(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      onDisabled?()
      return true
    }
    guard type.rawValue == 14, let auxiliary = NSEvent(cgEvent: event),
      auxiliary.subtype.rawValue == 8
    else { return false }
    return onData?(
      auxiliary.data1, event.flags.contains(.maskShift), event.flags.contains(.maskAlternate)
    ) ?? false
  }

  isolated deinit {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CFMachPortInvalidate(tap) }
  }
}

private func systemMediaKeyCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let context else { return Unmanaged.passUnretained(event) }
  let driver = Unmanaged<SystemMediaKeyTap>.fromOpaque(context).takeUnretainedValue()
  // This source is installed only on the main run loop; no asynchronous actor hop is made.
  struct EventReference: @unchecked Sendable { let event: CGEvent }
  let reference = EventReference(event: event)
  let swallowed = MainActor.assumeIsolated {
    driver.receive(type: type, event: reference.event)
  }
  return swallowed ? nil : Unmanaged.passUnretained(event)
}
