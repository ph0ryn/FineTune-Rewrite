// Shared native-pointer dispatcher for the rendered leaf fixtures and the native-button regression.
// A native NSButtonCell waits in the event-tracking run loop mode for the release, so the UP is
// posted by a cancellable one-shot timer installed in that mode; a target that handles DOWN
// synchronously never runs that mode, so the UP is sent directly after DOWN instead.
import AppKit
import Testing

/// Sends one left-button press/release pair in window-base coordinates.
@MainActor
func sendMouseClick(in window: NSWindow, at location: CGPoint) throws {
  let down = try mouseEvent(.leftMouseDown, in: window, at: location)
  let up = try mouseEvent(.leftMouseUp, in: window, at: location)
  let poster = TrackingUpPoster(up: up, window: window)
  let timer = Timer(
    timeInterval: 0, target: poster,
    selector: #selector(TrackingUpPoster.postOwnedUp), userInfo: nil, repeats: false)
  RunLoop.main.add(timer, forMode: .eventTracking)
  defer { timer.invalidate() }
  window.sendEvent(down)
  // A one-shot timer invalidates itself when the tracking activation runs it. If it is still
  // valid no event-tracking loop ran, so deliver the UP directly in the old non-tracking order.
  guard timer.isValid else { return }
  window.sendEvent(up)
}

/// Posts the owned UP from inside the main run loop's event-tracking mode.
@MainActor
private final class TrackingUpPoster: NSObject {
  private let up: NSEvent
  private let window: NSWindow

  init(up: NSEvent, window: NSWindow) {
    self.up = up
    self.window = window
  }

  @objc func postOwnedUp() {
    window.postEvent(up, atStart: true)
  }
}

@MainActor
private func mouseEvent(
  _ type: NSEvent.EventType, in window: NSWindow, at location: CGPoint
) throws -> NSEvent {
  try #require(
    NSEvent.mouseEvent(
      with: type, location: location, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
}
