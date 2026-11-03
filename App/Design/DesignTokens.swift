import AppKit
import SwiftUI

/// The fixed compatibility palette and metrics shared by the App's production views.
/// These are presentation values; saved preferences and audio decisions stay outside App.
enum DesignTokens {
  enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
  }

  enum Dimensions {
    static let popupWidth: CGFloat = 510
    static let contentPadding = Spacing.lg
    static var contentWidth: CGFloat { popupWidth - 2 * contentPadding }
    static let maxScrollHeight: CGFloat = 400
    static let cornerRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 6
    static let iconSize: CGFloat = 22
    static let iconSizeSmall: CGFloat = 14
    static let sliderTrackHeight: CGFloat = 3
    static let sliderThumbWidth: CGFloat = 16
    static let sliderThumbHeight: CGFloat = 10
    static let sliderThumbSize: CGFloat = 12
    static let minTouchTarget: CGFloat = 16
    static let rowContentHeight: CGFloat = 28
    static let sliderWidth: CGFloat = 140
    static let sliderMinWidth: CGFloat = 120
    static let percentageWidth: CGFloat = 40
    static let vuMeterBarCount = 8
    static let settingsIconWidth: CGFloat = 24
    static let settingsSliderWidth: CGFloat = 200
    static let settingsPercentageWidth: CGFloat = 44
    static let settingsPickerWidth: CGFloat = 120
  }

  enum Typography {
    static let sectionHeader = Font.system(size: 12, weight: .bold)
    static let sectionHeaderTracking: CGFloat = 1.2
    static let rowName = Font.system(size: 13)
    static let rowNameBold = Font.system(size: 13, weight: .semibold)
    static let percentage = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let caption = Font.system(size: 10)
    static let pickerText = Font.system(size: 11)
    static let eqLabel = Font.system(size: 9, weight: .medium, design: .monospaced)
    static let cardProfileName = Font.system(size: 12, weight: .semibold)
    static let cardSource = Font.system(size: 9)
    static let cardHeader = Font.system(size: 13, weight: .semibold)
    static let rowDescription = Font.system(size: 11)
  }

  enum Timing {
    static let vuMeterUpdateInterval: TimeInterval = 1 / 30
    static let vuMeterPeakHold: TimeInterval = 0.5
  }

  enum Animation {
    static let quick = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 0.85)
    static let hover = SwiftUI.Animation.easeOut(duration: 0.12)
    static let vuMeterLevel = SwiftUI.Animation.linear(duration: 0.05)
  }

  enum Colors {
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let textQuaternary = Color(nsColor: .quaternaryLabelColor)
    static let interactiveDefault = Color.primary.opacity(0.7)
    static let interactiveHover = Color.primary.opacity(0.9)
    static let interactiveActive = Color.primary
    static let accentPrimary = Color.accentColor
    static let mutedIndicator = Color(nsColor: .systemRed).opacity(0.85)
    static let defaultDevice = Color.accentColor
    static let separator = Color(nsColor: .separatorColor)
    static let glassBorder = separator.opacity(0.3)
    static let glassBorderHover = separator.opacity(0.5)
    static let sliderTrack = Color.primary.opacity(0.15)
    static let sliderFill = Color.accentColor
    static let sliderThumb = Color.white
    static let unityMarker = Color.primary.opacity(0.5)
    static let thumbBackground = Color.white
    static let thumbDot = Color.black.opacity(0.7)
    static let menuBackground = Color.clear
    static let pickerBackground = Color.primary.opacity(0.08)
    static let pickerHover = Color.primary.opacity(0.12)

    // No NSColor names are registered: distinct providers cannot alias through its name cache.
    static let popupOverlay = adaptive(light: (1, 0.50), dark: (0, 0.4))
    static let recessedBackground = adaptive(light: (0, 0.04), dark: (0, 0.3))
    static let menuBorder = adaptive(light: (0, 0.18), dark: (1, 0.12))
    static let menuBorderHover = adaptive(light: (0, 0.32), dark: (1, 0.25))
    static let autoEQEmptyBorder = adaptive(light: (0, 0.22), dark: (1, 0.1))
    static let autoEQEmptyIcon = adaptive(light: (0.45, 1), dark: (0.267, 1))
    static let autoEQToggleLabel = adaptive(light: (0, 0.65), dark: (1, 0.5))
    static let hoverSurface = adaptive(light: (0, 0.115), dark: (1, 0.07))
    static let glassFill = Color.clear
    static let glassFillStrong = adaptive(light: (1, 0.85), dark: (1, 0.1))
    static let glassRowBorder = Color.clear
    static let glassRowBorderHover = adaptive(light: (0, 0.10), dark: (1, 0.15))
    static let hudBorder = adaptive(light: (0, 0.15), dark: (1, 0.08))
    static let sectionHeaderText = adaptive(light: (0, 0.65), dark: (1, 0.40))
    static let eqCardBackground = adaptive(light: (1, 0.78), dark: (1, 0.07))
    static let eqCardBorder = adaptive(light: (0, 0.06), dark: (1, 0.10))
    static let deviceBadgeMonoFill = adaptive(light: (0, 0.10), dark: (1, 0.10))
    static let deviceBadgeMonoForeground = adaptive(light: (0, 0.65), dark: (1, 0.70))

    static let vuGreen = Color(red: 0.20, green: 0.78, blue: 0.40)
    static let vuYellow = Color(red: 0.95, green: 0.75, blue: 0.20)
    static let vuOrange = Color(red: 0.95, green: 0.50, blue: 0.20)
    static let vuRed = Color(red: 0.90, green: 0.25, blue: 0.25)
    static let vuUnlit = sliderTrack
    static let vuMuted = Color.primary.opacity(0.35)
    static let hudDotActive = Color.primary.opacity(0.85)
    static let hudDotInactive = Color.primary.opacity(0.18)
    static let hudTileActive = Color.primary.opacity(0.7)
    static let hudTileInactive = Color.primary.opacity(0.2)

    private static func adaptive(
      light: (white: CGFloat, alpha: CGFloat),
      dark: (white: CGFloat, alpha: CGFloat)
    ) -> Color {
      Color(
        nsColor: NSColor(name: nil) { appearance in
          let components =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
          return NSColor(white: components.white, alpha: components.alpha)
        })
    }
  }
}
