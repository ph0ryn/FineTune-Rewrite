// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/Components/LiquidGlassSlider.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: volume-only binding, native accessibility label and focus visibility.

import SwiftUI

/// Original thin-track presentation; native Slider still owns dragging and accessibility.
struct MixerVolumeSlider: View {
  @Binding var value: Double
  let label: String
  var isDimmed = false
  @State private var isHovered = false
  @State private var isEditing = false
  @FocusState private var isFocused: Bool

  private let trackHeight: CGFloat = 4

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        ZStack(alignment: .leading) {
          Capsule().fill(DesignTokens.Colors.sliderTrack)
          Capsule().fill(DesignTokens.Colors.accentPrimary)
            .frame(width: max(trackHeight, geometry.size.width * value))
        }
        .frame(height: trackHeight)
        .opacity(isDimmed ? 0.5 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)

        Slider(value: $value, in: 0...1, onEditingChanged: { isEditing = $0 }) {
          Text(label)
        }
        .labelsHidden()
        .controlSize(.mini)
        .tint(.clear)
        .focused($isFocused)
        // Keep the idle control at 0.01 even when muted: multiplying by a row opacity can
        // drop it below SwiftUI's hit-testing threshold and prevent volume edits while muted.
        .opacity(isHovered || isEditing || isFocused ? (isDimmed ? 0.5 : 1) : 0.01)
      }
    }
    .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
    .onHover { isHovered = $0 }
  }
}
