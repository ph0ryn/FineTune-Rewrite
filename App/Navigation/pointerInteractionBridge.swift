import AppKit
import SwiftUI

/// Reports mouse clicks and scrolling inside its own window; SwiftUI hover covers pointer movement.
private struct PointerInteractionBridge: NSViewRepresentable {
  let onInteraction: () -> Void

  func makeNSView(context: Context) -> InteractionView {
    InteractionView()
  }

  func updateNSView(_ nsView: InteractionView, context: Context) {
    nsView.onInteraction = onInteraction
  }

  /// An invisible pass-through view whose local monitor observes clicks inside its own window only.
  final class InteractionView: NSView {
    var onInteraction: (() -> Void)?
    private var monitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { removeMonitor() }
      super.viewWillMove(toWindow: newWindow)
      if newWindow != nil, monitor == nil {
        monitor = NSEvent.addLocalMonitorForEvents(
          matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
          guard let self, event.window === self.window else { return event }
          self.onInteraction?()
          return event
        }
      }
    }

    isolated deinit { removeMonitor() }

    private func removeMonitor() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

extension View {
  /// Calls back when the mouse is clicked or scrolled inside the hosting popup window. The event is
  /// observed, never consumed; hover and movement belong to SwiftUI's own hover modifiers.
  func pointerInteraction(perform action: @escaping () -> Void) -> some View {
    overlay(PointerInteractionBridge(onInteraction: action))
  }
}
