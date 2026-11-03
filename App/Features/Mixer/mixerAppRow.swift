import FineTuneDomain
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
        if let icon = app.icon {
          Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
          Image(systemName: "app.fill").frame(width: 22, height: 22)
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

  private var editControls: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      Button {
        bindings.actions.app.setPinned(app.id, !app.isPinned)
      } label: {
        Image(systemName: app.isPinned ? "pin.fill" : "pin")
      }
      .accessibilityLabel(app.isPinned ? "Unpin \(app.name)" : "Pin \(app.name)")
      .disabled(app.isIgnored)
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
      Slider(value: bindings.appVolume(app), in: 0...1)
        .frame(minWidth: 80, maxWidth: DesignTokens.Dimensions.sliderWidth)
        .scrollWheelStep(bindings.appVolume(app), in: 0...1)
        .accessibilityLabel("\(app.name) volume")
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
      Button {
        bindings.followDefault(app)
      } label: {
        if app.isFollowingDefault {
          Label("System Default", systemImage: "checkmark")
        } else {
          Text("System Default")
        }
      }
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
        Button {
          let current = bindings.current(app)
          var uids = current.selectionMode == .multi ? current.selectedDeviceUIDs : []
          if current.selectionMode == .multi && uids.contains(device.id) {
            uids.remove(device.id)
          } else {
            uids.insert(device.id)
          }
          bindings.selectRoute(current, mode: current.selectionMode, uids: uids)
        } label: {
          if !app.isFollowingDefault && app.selectedDeviceUIDs.contains(device.id) {
            Label(device.device.name, systemImage: "checkmark")
          } else {
            Text(device.device.name)
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
