// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/Components/DeviceBadge.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: use Rewrite's shared palette and device-row composition.

import AppKit
import SwiftUI

/// The documented badge selection styling. The view resolves this value once and renders every
/// layer from it; tests assert the same value instead of comparing whole bitmaps.
struct DeviceBadgeStyle: Equatable {
  enum Fill: Equatable { case accentGradient, mono }
  enum Glyph: Equatable { case white, mono }

  let fill: Fill
  let glyph: Glyph

  static func resolve(isSelected: Bool) -> Self {
    isSelected
      ? Self(fill: .accentGradient, glyph: .white)
      : Self(fill: .mono, glyph: .mono)
  }
}

/// Selection presentation only; the containing row owns the default-device action.
struct DeviceBadge: View {
  let icon: NSImage?
  let isSelected: Bool
  let fallbackSymbol: String

  private var style: DeviceBadgeStyle { .resolve(isSelected: isSelected) }

  var body: some View {
    ZStack {
      switch style.fill {
      case .accentGradient:
        Circle().fill(
          LinearGradient(
            colors: [
              DesignTokens.Colors.accentPrimary,
              DesignTokens.Colors.accentPrimary.opacity(0.78),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing))
      case .mono:
        Circle().fill(DesignTokens.Colors.deviceBadgeMonoFill)
      }
      Group {
        if let icon {
          Image(nsImage: icon).resizable().scaledToFit()
        } else {
          Image(systemName: fallbackSymbol).symbolRenderingMode(.hierarchical)
        }
      }
      .frame(width: 20, height: 20)
      .foregroundStyle(
        style.glyph == .white ? Color.white : DesignTokens.Colors.deviceBadgeMonoForeground)
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }
}
