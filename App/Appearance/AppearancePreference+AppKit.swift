import AppKit
import FineTuneDomain
import SwiftUI

extension AppearancePreference {
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  /// SwiftUI needs a concrete scheme to clear a previous explicit override.
  @MainActor
  var swiftUIColorScheme: ColorScheme? {
    switch self {
    case .light: .light
    case .dark: .dark
    case .system:
      NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? .dark : .light
    }
  }
}
