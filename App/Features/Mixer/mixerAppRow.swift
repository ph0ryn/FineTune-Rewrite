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

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if !isEditing {
          MixerLevelMeter(level: app.peakLevel, isMuted: app.isMuted, appName: app.name)
        }
        if app.isActive && !isEditing {
          Button {
            bindings.actions.app.activate(app.id)
          } label: {
            appIcon
          }
          .buttonStyle(.plain).accessibilityLabel("Open \(app.name)")
        } else {
          appIcon
        }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
          Text(app.name).font(DesignTokens.Typography.rowName).lineLimit(1).help(app.name)
          if !app.isActive && !isEditing {
            Text("Not playing").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isEditing {
          editControls
        } else {
          audioControls
        }
      }
      if !isEditing {
        HStack {
          routePicker
          Spacer()
          Button {
            withAnimation(DesignTokens.Animation.quick) { isEQExpanded.toggle() }
          } label: {
            Label("EQ", systemImage: isEQExpanded ? "chevron.up" : "slider.horizontal.3")
          }
          .buttonStyle(.plain)
          .font(DesignTokens.Typography.pickerText)
          .accessibilityLabel("\(isEQExpanded ? "Hide" : "Show") equalizer for \(app.name)")
        }
        if let status = app.routeStatus {
          Label(status, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.caption).foregroundStyle(.orange)
        }
        if isEQExpanded { MixerEqualizerPanel(app: app, bindings: bindings) }
      }
    }
    .padding(DesignTokens.Spacing.sm)
    .background(DesignTokens.Colors.recessedBackground, in: RoundedRectangle(cornerRadius: 10))
    .opacity(app.isIgnored ? 0.65 : 1)
    .contextMenu {
      Button(app.isPinned ? "Unpin" : "Pin") {
        bindings.actions.app.setPinned(app.id, !app.isPinned)
      }
      Button(app.isIgnored ? "Show App" : "Ignore App") {
        bindings.actions.app.setIgnored(app.id, !app.isIgnored)
      }
    }
  }

  @ViewBuilder private var appIcon: some View {
    if let icon = app.icon {
      Image(nsImage: icon).resizable().scaledToFit().frame(width: 22, height: 22)
    } else {
      Image(systemName: "app.fill").frame(width: 22, height: 22)
    }
  }

  private var editControls: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      if !app.isIgnored {
        Button {
          bindings.actions.app.setPinned(app.id, !app.isPinned)
        } label: {
          Image(systemName: app.isPinned ? "pin.fill" : "pin")
        }
        .accessibilityLabel(app.isPinned ? "Unpin \(app.name)" : "Pin \(app.name)")
      }
      Button {
        bindings.actions.app.setIgnored(app.id, !app.isIgnored)
      } label: {
        Image(systemName: app.isIgnored ? "eye.slash" : "eye")
      }
      .accessibilityLabel(app.isIgnored ? "Show \(app.name)" : "Ignore \(app.name)")
    }
    .buttonStyle(.plain)
  }

  private var audioControls: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button {
        bindings.appMute(app).wrappedValue.toggle()
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .foregroundStyle(app.isMuted ? DesignTokens.Colors.mutedIndicator : .primary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(app.isMuted ? "Unmute" : "Mute") \(app.name)")
      MixerVolumeSlider(
        value: bindings.appVolume(app), label: "\(app.name) volume",
        isDimmed: app.isMuted || Int((VolumeMapping.gainToSlider(app.gain) * 100).rounded()) == 0
      )
      .frame(width: DesignTokens.Dimensions.sliderWidth)
      .scrollWheelStep(bindings.appVolume(app), in: 0...1)
      if let percentageDraft {
        Text("\(percentageDraft)%").font(DesignTokens.Typography.percentage)
          .foregroundStyle(Color.accentColor)
          .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
      } else {
        VolumePercentageField(
          value: bindings.appVolume(app), range: 0...100, label: "\(app.name) volume percentage")
      }
      Button(app.boost.label) { bindings.appBoost(app).wrappedValue = app.boost.next }
        .buttonStyle(.plain)
        .font(DesignTokens.Typography.pickerText)
        .foregroundStyle(app.boost.isBoosted ? Color.accentColor : .secondary)
        .help("Volume boost")
    }
  }

  private var routePicker: some View {
    Menu {
      Toggle(
        isOn: Binding(
          get: { bindings.current(app).isFollowingDefault },
          set: { _ in bindings.followDefault(app) })
      ) {
        Label("System Default", systemImage: "speaker.wave.2")
      }
      .disabled(app.selectionMode == .multi)
      .help(
        app.selectionMode == .multi
          ? "System audio follows one output; choose single output mode to follow it."
          : "Follow the macOS default output")
      Divider()
      Toggle(
        "Multiple Outputs",
        isOn: Binding(
          get: { bindings.current(app).selectionMode == .multi },
          set: {
            let current = bindings.current(app)
            bindings.selectRoute(
              current, mode: $0 ? .multi : .single, uids: current.selectedDeviceUIDs)
          }
        ))
      ForEach(bindings.read().outputDevices.filter { !$0.isHidden }) { device in
        Toggle(
          isOn: Binding(
            get: {
              let current = bindings.current(app)
              return !current.isFollowingDefault && current.selectedDeviceUIDs.contains(device.id)
            },
            set: { _ in
              let current = bindings.current(app)
              var uids = current.selectionMode == .multi ? current.selectedDeviceUIDs : []
              if current.selectionMode == .multi && uids.contains(device.id) {
                uids.remove(device.id)
              } else {
                uids.insert(device.id)
              }
              bindings.selectRoute(current, mode: current.selectionMode, uids: uids)
            })
        ) {
          Label {
            Text(device.device.name + (device.isDefault ? " ★" : ""))
          } icon: {
            if let icon = bindings.deviceIcon(device, scope: .output) { Image(nsImage: icon) }
          }
        }
      }
    } label: {
      Text(bindings.routeLabel(app)).lineLimit(1).truncationMode(.middle)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: false, vertical: true)
    .font(DesignTokens.Typography.pickerText)
    .help(bindings.routeLabel(app))
    .accessibilityLabel("Output for \(app.name): \(bindings.routeLabel(app))")
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
