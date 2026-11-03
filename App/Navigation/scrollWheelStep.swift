import AppKit
import SwiftUI

/// Converts pointer scrolling to a slider delta; inertial tail events do not write a value.
enum ScrollWheelStep {
  static func apply<V: BinaryFloatingPoint>(
    deltaY: CGFloat, hasPreciseDeltas: Bool, isDirectionInverted: Bool,
    isMomentumTail: Bool, value: inout V, sensitivity: V, lineUnits: V = 10,
    in range: ClosedRange<V>
  ) {
    guard !isMomentumTail, deltaY != 0 else { return }
    let units = hasPreciseDeltas ? V(deltaY) : (deltaY > 0 ? lineUnits : -lineUnits)
    let change = units * sensitivity * (isDirectionInverted ? -1 : 1)
    value = min(range.upperBound, max(range.lowerBound, value + change))
  }

  static func apply<V: BinaryFloatingPoint>(
    event: NSEvent, value: inout V, sensitivity: V, lineUnits: V = 10,
    in range: ClosedRange<V>
  ) {
    apply(
      deltaY: event.scrollingDeltaY, hasPreciseDeltas: event.hasPreciseScrollingDeltas,
      isDirectionInverted: event.isDirectionInvertedFromDevice,
      isMomentumTail: !event.momentumPhase.isEmpty, value: &value, sensitivity: sensitivity,
      lineUnits: lineUnits, in: range
    )
  }
}

private struct ScrollWheelAdjustment<Value: BinaryFloatingPoint>: NSViewRepresentable {
  @Binding var value: Value
  let range: ClosedRange<Value>

  func makeNSView(context: Context) -> ScrollInputView {
    ScrollInputView()
  }

  func updateNSView(_ nsView: ScrollInputView, context: Context) {
    nsView.adjust = { event in
      ScrollWheelStep.apply(
        event: event, value: &value, sensitivity: (range.upperBound - range.lowerBound) / 200,
        in: range
      )
    }
  }

  /// A local monitor is scoped to this view's hover region and removed with the view.
  final class ScrollInputView: NSView {
    var adjust: ((NSEvent) -> Void)?
    private var monitor: Any?

    isolated deinit { removeMonitor() }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, event.window === self.window,
          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        else { return event }
        self.adjust?(event)
        return nil
      }
    }

    override func mouseExited(with event: NSEvent) { removeMonitor() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { removeMonitor() }
      super.viewWillMove(toWindow: newWindow)
    }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

extension View {
  func scrollWheelStep<Value: BinaryFloatingPoint>(
    _ value: Binding<Value>, in range: ClosedRange<Value>
  ) -> some View {
    overlay(ScrollWheelAdjustment(value: value, range: range))
  }
}
