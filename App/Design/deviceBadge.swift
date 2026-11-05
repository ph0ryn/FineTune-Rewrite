// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/Components/DeviceBadge.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: use Rewrite's shared palette and device-row composition.

import AppKit
import SwiftUI

/// Selection presentation only; the containing row owns the default-device action.
struct DeviceBadge: View {
  let icon: NSImage?
  let isSelected: Bool
  let fallbackSymbol: String

  var body: some View {
    ZStack {
      if isSelected {
        Circle().fill(
          LinearGradient(
            colors: [
              DesignTokens.Colors.accentPrimary,
              DesignTokens.Colors.accentPrimary.opacity(0.78),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing))
      } else {
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
      .foregroundStyle(isSelected ? Color.white : DesignTokens.Colors.deviceBadgeMonoForeground)
    }
    .frame(width: 28, height: 28)
    .accessibilityHidden(true)
  }
}
