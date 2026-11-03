import AppKit
import FineTuneDomain
import SwiftUI

/// Keeps AppKit materials and SwiftUI colors on the same appearance at window roots.
struct WindowAppearanceBridge: NSViewRepresentable {
  let appearance: NSAppearance?

  func makeNSView(context: Context) -> AppearanceHostView {
    AppearanceHostView()
  }

  func updateNSView(_ nsView: AppearanceHostView, context: Context) {
    nsView.appearanceOverride = appearance
    nsView.synchronize()
  }

  final class AppearanceHostView: NSView {
    var appearanceOverride: NSAppearance?
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observation = nil
      guard window != nil else { return }
      synchronize()
      observation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
        MainActor.assumeIsolated {
          guard let self, self.appearanceOverride == nil else { return }
          self.synchronize()
        }
      }
    }

    func synchronize() {
      window?.appearance = appearanceOverride ?? NSApplication.shared.effectiveAppearance
    }
  }
}

private struct AppearancePreferenceEnvironmentKey: EnvironmentKey {
  static let defaultValue = AppearancePreference.system
}

extension EnvironmentValues {
  var appearancePreference: AppearancePreference {
    get { self[AppearancePreferenceEnvironmentKey.self] }
    set { self[AppearancePreferenceEnvironmentKey.self] = newValue }
  }
}
