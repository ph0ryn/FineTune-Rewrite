// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/MenuBarPopupView.swift and Views/DesignSystem/ViewModifiers.swift
// at 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: snapshot inputs and explicit actions; preserve Rewrite's command-Q binding.

import SwiftUI

/// Compact original controls, independent of device services and application lifecycle.
struct MixerHeader: View {
  @Binding var scope: MixerDeviceScope
  let isEditing: Bool
  let outputName: String
  let inputName: String
  let edit: () -> Void
  let retryAudio: () -> Void
  let settings: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      deviceTabs
      Spacer(minLength: 0)
      if isEditing {
        Text("Drag or type a number to set priority")
          .font(DesignTokens.Typography.rowDescription)
          .foregroundStyle(DesignTokens.Colors.textSecondary)
      } else {
        defaultDevicesStatus
      }
      Spacer(minLength: 0)
      Button(
        isEditing ? "Done reordering" : "Reorder devices",
        systemImage: isEditing ? "checkmark" : "pencil", action: edit
      )
      .font(.system(size: 12, weight: isEditing ? .bold : .regular))
      .help(isEditing ? "Done reordering" : "Reorder devices")
      .modifier(HeaderIcon())

      Button("Retry Audio", systemImage: "arrow.clockwise", action: retryAudio)
        .font(.system(size: 12))
        .help("Retry Audio")
        .modifier(HeaderIcon())

      Button("Settings", systemImage: "gearshape.fill", action: settings)
        .font(.system(size: 12))
        .help("Settings")
        .modifier(HeaderIcon())
    }
    .padding(.bottom, DesignTokens.Spacing.xs)
  }

  private var deviceTabs: some View {
    HStack(spacing: 2) {
      ForEach(MixerDeviceScope.allCases) { tab in
        Button {
          scope = tab
        } label: {
          Image(systemName: tab == .output ? "speaker.wave.2.fill" : "mic.fill")
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(
              scope == tab ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary
            )
            .frame(width: 26, height: 26)
            .background {
              if scope == tab {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                  .fill(DesignTokens.Colors.glassFillStrong)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.title) Devices")
        .accessibilityAddTraits(scope == tab ? .isSelected : [])
        .help("\(tab.title) Devices")
      }
    }
    .padding(3)
    .fixedSize()
  }

  private var defaultDevicesStatus: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      deviceStatus(outputName, symbol: "speaker.wave.2.fill")
      Text("·")
      deviceStatus(inputName, symbol: "mic.fill")
    }
    .font(DesignTokens.Typography.rowDescription)
    .foregroundStyle(DesignTokens.Colors.textSecondary)
  }

  private func deviceStatus(_ name: String, symbol: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).font(.system(size: 9))
      Text(name).lineLimit(1).truncationMode(.middle)
    }
    .help(name)
  }

  private struct HeaderIcon: ViewModifier {
    func body(content: Content) -> some View {
      content
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
          minWidth: DesignTokens.Dimensions.minTouchTarget,
          minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
    }
  }
}

struct MixerFooter: View {
  let quit: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack {
      Spacer()
      Button(action: quit) {
        HStack(spacing: 6) {
          Text("Quit")
          Text("⌘Q").foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Colors.textSecondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule().strokeBorder(
            isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
            lineWidth: 0.5)
        }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
      .accessibilityLabel("Quit FineTune")
      .help("Quit FineTune (⌘Q)")
      .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : DesignTokens.Animation.hover, value: isHovered)
    }
  }
}
