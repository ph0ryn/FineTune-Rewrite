import SwiftUI

private enum HUDGlyph {
  static func name(fraction: Float) -> String {
    switch Int((max(0, min(1, fraction)) * 100).rounded()) {
    case 0: "speaker.fill"
    case 1...33: "speaker.wave.1.fill"
    case 34...66: "speaker.wave.2.fill"
    default: "speaker.wave.3.fill"
    }
  }
}

/// Interactive device volume HUD. Values are slider fractions, never PCM gains.
struct TahoeStyleHUD: View {
  let sliderFraction: Float
  let mute: Bool
  let deviceName: String
  var onSliderChange: (@MainActor @Sendable (Float) -> Void)?
  var onHoverChange: (@MainActor @Sendable (Bool) -> Void)?
  @State private var dragValue: Double?

  static var nameFont: Font { DesignTokens.Typography.rowNameBold }

  nonisolated init(
    sliderFraction: Float, mute: Bool, deviceName: String,
    onSliderChange: (@MainActor @Sendable (Float) -> Void)? = nil,
    onHoverChange: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    self.sliderFraction = sliderFraction
    self.mute = mute
    self.deviceName = deviceName
    self.onSliderChange = onSliderChange
    self.onHoverChange = onHoverChange
  }

  nonisolated var waveIconNameForTest: String { HUDGlyph.name(fraction: sliderFraction) }

  private var displayedValue: Double { max(0, min(1, dragValue ?? Double(sliderFraction))) }
  private var percentage: Int { Int((displayedValue * 100).rounded()) }
  private var displayedMute: Bool { dragValue == nil ? mute : percentage == 0 }
  private var slider: Binding<Double> {
    Binding(
      get: { displayedValue },
      set: { value in
        dragValue = value
        onSliderChange?(Float(value))
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(deviceName.isEmpty ? " " : deviceName)
        .font(Self.nameFont)
        .foregroundStyle(DesignTokens.Colors.textPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        Image(
          systemName: displayedMute
            ? "speaker.slash.fill" : HUDGlyph.name(fraction: Float(displayedValue))
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(
          displayedMute ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.hudTileActive
        )
        .frame(width: 18, height: 18)
        Slider(value: slider, in: 0...1)
          .labelsHidden()
          .opacity(displayedMute ? 0.5 : 1)
          .scrollWheelStep(slider, in: 0...1)
          .accessibilityLabel("Volume")
        Text("\(percentage)%")
          .font(.system(size: 11, weight: .semibold).monospacedDigit())
          .foregroundStyle(DesignTokens.Colors.textSecondary)
          .frame(width: 36, alignment: .trailing)
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
    .frame(width: 300, height: 72)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    .overlay(
      RoundedRectangle(cornerRadius: 22).strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
    )
    .onHover { onHoverChange?($0) }
    .onChange(of: sliderFraction) { _, _ in dragValue = nil }
    .onChange(of: mute) { _, _ in dragValue = nil }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(deviceName.isEmpty ? "Unknown device" : deviceName)
  }
}

struct ClassicStyleHUD: View {
  let sliderFraction: Float
  let mute: Bool
  nonisolated static let hasPercentageLabel = false

  nonisolated init(sliderFraction: Float, mute: Bool) {
    self.sliderFraction = sliderFraction
    self.mute = mute
  }

  nonisolated var waveIconNameForTest: String {
    HUDGlyph.name(fraction: mute ? 0 : sliderFraction)
  }

  private var filledTiles: Int {
    Int((max(0, min(1, mute ? 0 : sliderFraction)) * 16).rounded())
  }

  var body: some View {
    VStack(spacing: 0) {
      Image(systemName: mute ? "speaker.slash.fill" : waveIconNameForTest)
        .font(.system(size: 80, weight: .medium))
        .foregroundStyle(DesignTokens.Colors.hudTileActive)
        .frame(height: 140)
      HStack(spacing: 2) {
        ForEach(0..<16, id: \.self) { index in
          Rectangle()
            .fill(
              index < filledTiles
                ? DesignTokens.Colors.hudTileActive : DesignTokens.Colors.hudTileInactive
            )
            .frame(width: 7.5, height: 7.5)
        }
      }
      .frame(height: 40)
    }
    .frame(width: 200, height: 200)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16).strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      mute ? "Muted" : "Volume \(Int((max(0, min(1, sliderFraction)) * 100).rounded())) percent")
  }
}
