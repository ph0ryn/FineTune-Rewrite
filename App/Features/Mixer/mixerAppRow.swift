// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/Rows/{AppRow,InactiveAppRow,AppRowControls,AppEditRow}.swift
// and Views/Components/{ExpandableGlassRow,BoostChevrons,MuteButton}.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: existing common bindings/slider, native percentage editing and observed levels.

import FineTuneDomain
import Foundation
import SwiftUI

@MainActor
struct MixerAppRow: View {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  let isEditing: Bool
  let percentageDraft: String?
  @Binding var isEQExpanded: Bool
  var isFocused = false
  @State private var isHovered = false
  @State private var isIconHovered = false
  @State private var isMuteHovered = false
  @State private var isBoostHovered = false
  @State private var isEQHovered = false
  @State private var isPinHovered = false
  @State private var isEyeHovered = false

  private var decorationOpacity: Double { app.isActive || isEditing ? 1 : 0.6 }
  private var sliderValue: Double { VolumeMapping.gainToSlider(app.gain) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if !isEditing {
          MixerLevelMeter(level: app.peakLevel, isMuted: app.isMuted, appName: app.name)
            .opacity(decorationOpacity)
        }
        if app.isActive && !isEditing {
          Button {
            bindings.actions.app.activate(app.id)
          } label: {
            appIcon.opacity(isIconHovered ? 0.7 : 1)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open \(app.name)")
          .onHover { isIconHovered = $0 }
        } else {
          appIcon
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(app.name).font(DesignTokens.Typography.rowName).lineLimit(1).help(app.name)
            .foregroundStyle(app.isIgnored ? DesignTokens.Colors.textSecondary : .primary)
          if !isEditing, let subtitle = MixerAppRoutePicker.subtitle(app, bindings: bindings) {
            Text(subtitle).font(.system(size: 9))
              .foregroundStyle(DesignTokens.Colors.textTertiary)
              .lineLimit(1).help(bindings.routeLabel(app))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(decorationOpacity)
        if isEditing { editControls } else { audioControls }
      }
      .frame(height: DesignTokens.Dimensions.rowContentHeight)
      if !isEditing {
        if let status = app.routeStatus {
          Label(status, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.caption).foregroundStyle(.orange)
            .padding(.top, DesignTokens.Spacing.xs)
        }
        if isEQExpanded {
          MixerEqualizerPanel(app: app, bindings: bindings)
            .padding(.top, DesignTokens.Spacing.sm)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, 6)
    .background {
      RoundedRectangle(
        cornerRadius: isEditing
          ? DesignTokens.Dimensions.buttonRadius : DesignTokens.Dimensions.rowRadius
      )
      .fill(
        isHovered || isFocused || (!isEditing && isEQExpanded)
          ? DesignTokens.Colors.hoverSurface : .clear
      )
      .padding(.vertical, 1)
      .allowsHitTesting(false)
    }
    .onHover { isHovered = $0 }
    .animation(DesignTokens.Animation.hover, value: isHovered)
    .animation(DesignTokens.Animation.hover, value: isFocused)
    .contextMenu {
      Button(app.isPinned ? "Unpin" : "Pin") {
        bindings.actions.app.setPinned(app.id, !app.isPinned)
      }
      Button(app.isIgnored ? "Show App" : "Ignore App") {
        bindings.actions.app.setIgnored(app.id, !app.isIgnored)
      }
    }
  }

  private var appIcon: some View {
    let size =
      isEditing
      ? DesignTokens.Dimensions.iconSize : DesignTokens.Dimensions.rowContentHeight - 4
    return Group {
      if let icon = app.icon {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        Image(systemName: "app.fill").resizable().scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .opacity(app.isIgnored ? 0.4 : decorationOpacity)
    .accessibilityHidden(true)
  }

  private var editControls: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if !app.isIgnored {
        Button {
          bindings.actions.app.setPinned(app.id, !app.isPinned)
        } label: {
          Image(systemName: app.isPinned ? "pin.fill" : "pin")
            .font(.system(size: 12)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(
              app.isPinned
                ? DesignTokens.Colors.accentPrimary
                : (isPinHovered
                  ? DesignTokens.Colors.interactiveHover
                  : DesignTokens.Colors.interactiveDefault)
            )
            .frame(
              minWidth: DesignTokens.Dimensions.minTouchTarget,
              minHeight: DesignTokens.Dimensions.minTouchTarget
            ).contentShape(Rectangle())
            .scaleEffect(isPinHovered ? 1.1 : 1)
        }
        .accessibilityLabel(app.isPinned ? "Unpin \(app.name)" : "Pin \(app.name)")
        .help(app.isPinned ? "Unpin app" : "Pin app")
        .onHover { isPinHovered = $0 }
        .animation(DesignTokens.Animation.quick, value: isPinHovered)
      }
      Button {
        bindings.actions.app.setIgnored(app.id, !app.isIgnored)
      } label: {
        Image(systemName: app.isIgnored ? "eye.slash" : "eye")
          .font(.system(size: 13)).symbolRenderingMode(.hierarchical)
          .foregroundStyle(
            isEyeHovered
              ? DesignTokens.Colors.interactiveHover
              : DesignTokens.Colors.interactiveDefault
          )
          .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
          ).contentShape(Rectangle())
          .scaleEffect(isEyeHovered ? 1.1 : 1)
      }
      .accessibilityLabel(app.isIgnored ? "Show \(app.name)" : "Ignore \(app.name)")
      .help(app.isIgnored ? "Stop ignoring" : "Ignore app")
      .onHover { isEyeHovered = $0 }
      .animation(DesignTokens.Animation.quick, value: isEyeHovered)
    }
    .buttonStyle(.plain)
  }

  private var audioControls: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      muteButton
      // Do not dim the ancestor: native idle opacity must stay above the hit-test threshold.
      MixerVolumeSlider(
        value: bindings.appVolume(app), label: "\(app.name) volume",
        isDimmed: !app.isActive || app.isMuted || Int((sliderValue * 100).rounded()) == 0
      )
      .frame(width: DesignTokens.Dimensions.sliderWidth)
      .scrollWheelStep(bindings.appVolume(app), in: 0...1)
      Group {
        if let percentageDraft {
          Text("\(percentageDraft)%").font(DesignTokens.Typography.percentage)
            .foregroundStyle(Color.accentColor)
            .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
        } else {
          VolumePercentageField(
            value: bindings.appVolume(app), range: 0...100, label: "\(app.name) volume percentage")
        }
      }
      .opacity(decorationOpacity)
      boostButton.opacity(decorationOpacity)
      MixerAppRoutePicker(app: app, bindings: bindings).opacity(decorationOpacity)
      equalizerButton.opacity(decorationOpacity)
    }
    .fixedSize()
  }

  private var muteButton: some View {
    Button {
      bindings.appMute(app).wrappedValue.toggle()
    } label: {
      ZStack {
        Image(systemName: "speaker.wave.3.fill").opacity(0)
        Image(
          systemName: app.isMuted
            ? "speaker.slash.fill"
            : VolumeBucket.bucket(for: Float(sliderValue)).symbolName)
      }
      .font(.system(size: 14)).symbolRenderingMode(.hierarchical)
      .foregroundStyle(
        app.isMuted
          ? DesignTokens.Colors.mutedIndicator
          : (isMuteHovered
            ? DesignTokens.Colors.interactiveHover
            : DesignTokens.Colors.interactiveDefault)
      )
      .frame(
        minWidth: DesignTokens.Dimensions.minTouchTarget,
        minHeight: DesignTokens.Dimensions.minTouchTarget
      ).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(app.isMuted ? "Unmute" : "Mute") \(app.name)")
    .help(app.isMuted ? "Unmute" : "Mute")
    .onHover { isMuteHovered = $0 }
    .animation(DesignTokens.Animation.hover, value: isMuteHovered)
    .opacity(decorationOpacity)
  }

  private var boostButton: some View {
    Button {
      bindings.appBoost(app).wrappedValue = app.boost.next
    } label: {
      VStack(spacing: -2) {
        ForEach((0..<3).reversed(), id: \.self) { index in
          Image(systemName: "chevron.compact.up")
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(
              index < Int(app.boost.rawValue) - 1
                ? DesignTokens.Colors.accentPrimary
                : Color.primary.opacity(isBoostHovered ? 0.25 : 0.15))
        }
      }
      .frame(
        minWidth: DesignTokens.Dimensions.minTouchTarget,
        minHeight: DesignTokens.Dimensions.minTouchTarget
      ).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Volume boost: \(app.boost.label)")
    .accessibilityLabel("Volume boost for \(app.name): \(app.boost.label)")
    .onHover { isBoostHovered = $0 }
    .animation(.snappy(duration: 0.2), value: app.boost)
    .animation(DesignTokens.Animation.hover, value: isBoostHovered)
  }

  private var equalizerButton: some View {
    Button {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isEQExpanded.toggle() }
    } label: {
      ZStack {
        Image(systemName: "slider.vertical.3")
          .opacity(isEQExpanded ? 0 : 1).rotationEffect(.degrees(isEQExpanded ? 90 : 0))
        Image(systemName: "xmark")
          .opacity(isEQExpanded ? 1 : 0).rotationEffect(.degrees(isEQExpanded ? 0 : -90))
      }
      .font(.system(size: 12)).symbolRenderingMode(.hierarchical)
      .foregroundStyle(
        isEQExpanded
          ? DesignTokens.Colors.interactiveActive
          : (isEQHovered
            ? DesignTokens.Colors.interactiveHover
            : DesignTokens.Colors.interactiveDefault)
      )
      .frame(
        minWidth: DesignTokens.Dimensions.minTouchTarget,
        minHeight: DesignTokens.Dimensions.minTouchTarget
      ).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(isEQExpanded ? "Hide" : "Show") equalizer for \(app.name)")
    .help(isEQExpanded ? "Close Equalizer" : "Equalizer")
    .onHover { isEQHovered = $0 }
    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEQExpanded)
    .animation(DesignTokens.Animation.hover, value: isEQHovered)
  }
}

/// Displays only cached observed native levels. Missing telemetry is distinct from measured silence.
@MainActor
struct MixerLevelMeter: View {
  let level: Float?
  let isMuted: Bool
  let appName: String

  private var decibels: Float? {
    level.map { $0 == 0 ? -.infinity : 20 * log10($0) }
  }

  var body: some View {
    Group {
      if level == nil {
        Text("—").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
      } else {
        VStack(spacing: 1) {
          ForEach((0..<DesignTokens.Dimensions.vuMeterBarCount).reversed(), id: \.self) { index in
            let threshold = Float([-40, -30, -20, -14, -10, -6, -3, 0][index])
            let isLit = decibels.map { $0 >= threshold } ?? false
            RoundedRectangle(cornerRadius: 0.5)
              .fill(isLit ? barColor(index) : DesignTokens.Colors.vuUnlit)
          }
        }
      }
    }
    .frame(width: 10, height: DesignTokens.Dimensions.rowContentHeight - 4)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio level for \(appName)")
    .accessibilityValue(levelDescription)
    .help(levelDescription)
  }

  private var levelDescription: String {
    guard let decibels else { return "Audio level unavailable" }
    if isMuted { return "Muted" }
    return decibels == -.infinity ? "−∞ dB" : String(format: "%.1f dB", decibels)
  }

  private func barColor(_ index: Int) -> Color {
    if isMuted { return DesignTokens.Colors.vuMuted }
    switch index {
    case 0..<4: return DesignTokens.Colors.vuGreen
    case 4..<6: return DesignTokens.Colors.vuYellow
    case 6: return DesignTokens.Colors.vuOrange
    default: return DesignTokens.Colors.vuRed
    }
  }
}

/// Native text editing owns its temporary draft; writes use the same live binding as the slider.
@MainActor
struct VolumePercentageField: View {
  @Binding var value: Double
  let range: ClosedRange<Int>
  let label: String

  var boundedValue: Binding<Double> {
    Binding(
      get: { value },
      set: { value = max(Double(range.lowerBound) / 100, min(Double(range.upperBound) / 100, $0)) }
    )
  }

  var body: some View {
    TextField("", value: boundedValue, format: .percent.precision(.fractionLength(0)))
      .textFieldStyle(.plain).multilineTextAlignment(.trailing)
      .font(DesignTokens.Typography.percentage)
      .frame(width: DesignTokens.Dimensions.percentageWidth)
      .accessibilityLabel(label)
  }
}
