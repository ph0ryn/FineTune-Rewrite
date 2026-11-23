import FineTuneDomain
import SwiftUI

/// Applying an EQ choice and dismissing its picker are one action. A native nested `Menu` can lose
/// menu tracking inside the menu-bar popover (submenu vanishes, parent stays open), so the picker
/// owns its presentation state instead.
@MainActor
struct MixerEQPresetSelection {
  let applyBuiltIn: (EQPreset) -> Void
  let applyCurve: (EQSettings) -> Void
  let close: () -> Void

  func select(_ preset: EQPreset) {
    applyBuiltIn(preset)
    close()
  }

  func select(_ curve: EQSettings) {
    applyCurve(curve)
    close()
  }
}

@MainActor
struct MixerEqualizerPanel: View {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  @State private var isNamingPreset = false
  @State private var presetName = ""
  @State private var renamingPresetID: UUID?
  @State private var isPresetListPresented = false
  @State private var scrollGeometry = ScrollGeometry(
    contentOffset: .zero, contentSize: .zero, contentInsets: EdgeInsets(), containerSize: .zero)

  private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

  private var matchingBuiltIn: EQPreset? {
    EQPreset.allCases.first { $0.settings.bandGains == app.eqSettings.bandGains }
  }

  private var matchingUserPreset: UserEQPreset? {
    bindings.snapshot.userPresets.first { $0.settings.bandGains == app.eqSettings.bandGains }
  }

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      HStack {
        Toggle("EQ", isOn: bindings.eqEnabled(app)).toggleStyle(.switch).controlSize(.mini)
          .font(DesignTokens.Typography.pickerText)
        Spacer()
        if let user = matchingUserPreset, matchingBuiltIn == nil {
          Button("Rename…") { beginNaming(user) }.buttonStyle(.plain)
        } else if matchingBuiltIn == nil {
          Button("Save Preset…") { beginNaming(nil) }.buttonStyle(.plain)
        }
        presetMenu
      }
      HStack(spacing: 0) {
        ForEach(0..<EQSettings.bandCount, id: \.self) { index in
          VStack(spacing: DesignTokens.Spacing.xs) {
            Text(String(format: "%+.0f dB", app.eqSettings.bandGains[index]))
              .font(DesignTokens.Typography.eqLabel)
              .foregroundStyle(.secondary)
            Slider(value: bindings.eqBand(app, index: index), in: -12...12)
              .frame(width: 90)
              .rotationEffect(.degrees(-90))
              .frame(width: 24, height: 92)
              .scrollWheelStep(bindings.eqBand(app, index: index), in: -12...12)
              .disabled(!app.eqSettings.isEnabled)
              .accessibilityLabel("\(frequencyLabels[index]) Hz gain")
            VStack(spacing: 0) {
              Text(frequencyLabels[index]).font(DesignTokens.Typography.eqLabel)
              Text("Hz").font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
            }
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(DesignTokens.Colors.eqCardBackground, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DesignTokens.Colors.eqCardBorder))
    .alert(
      renamingPresetID == nil ? "Save EQ Preset" : "Rename EQ Preset", isPresented: $isNamingPreset
    ) {
      TextField("Preset name", text: $presetName)
      Button("Cancel", role: .cancel) { renamingPresetID = nil }
      Button("Save") {
        if let id = renamingPresetID {
          bindings.actions.app.renamePreset(id, presetName)
        } else {
          bindings.actions.app.createPreset(presetName, bindings.freshApp(app).eqSettings)
        }
        renamingPresetID = nil
      }
      .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private var selection: MixerEQPresetSelection {
    MixerEQPresetSelection(
      applyBuiltIn: { bindings.applyPreset($0, to: app) },
      applyCurve: { bindings.applyCurve($0, to: app) },
      close: { isPresetListPresented = false })
  }

  private var presetMenu: some View {
    Button {
      isPresetListPresented.toggle()
    } label: {
      HStack(spacing: DesignTokens.Spacing.xxs) {
        Text(matchingBuiltIn?.name ?? matchingUserPreset?.name ?? "Custom").lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .font(DesignTokens.Typography.pickerText)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, DesignTokens.Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
          .fill(DesignTokens.Colors.pickerBackground)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .popover(isPresented: $isPresetListPresented, arrowEdge: .bottom) {
      presetList.frame(width: 190)
    }
    .accessibilityLabel("EQ preset for \(app.name)")
  }

  private var presetList: some View {
    ZStack(alignment: .topTrailing) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          let userPresets = bindings.snapshot.userPresets
          if !userPresets.isEmpty {
            sectionHeader("My Presets")
            ForEach(userPresets) { preset in userPresetRow(preset) }
          }
          ForEach(EQPreset.Category.allCases) { category in
            sectionHeader(category.rawValue)
            ForEach(EQPreset.presets(for: category)) { preset in presetRow(preset) }
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
      }
      // The native indicator sits on the popover's rounded edge and is too wide; draw a slim one
      // inside the corner instead, keeping scroll and its position feedback intact.
      .scrollIndicators(.never)
      .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
        geometry
      } action: { _, new in
        scrollGeometry = new
      }

      if scrollGeometry.contentSize.height > scrollGeometry.containerSize.height {
        scrollThumb
          .padding(.trailing, DesignTokens.Spacing.sm)
          .padding(.vertical, DesignTokens.Spacing.sm)
          .allowsHitTesting(false)
      }
    }
    .frame(width: 190, height: 320)
  }

  private var scrollThumb: some View {
    let viewport = scrollGeometry.containerSize.height
    let content = scrollGeometry.contentSize.height
    let track = max(0, viewport - 2 * DesignTokens.Spacing.sm)
    let thumb = max(24, track * viewport / content)
    let progress = min(
      1, max(0, scrollGeometry.visibleRect.minY / max(1, content - viewport)))
    return ZStack(alignment: .top) {
      Capsule().fill(Color.primary.opacity(0.12))
        .frame(width: 3, height: track)
      Capsule().fill(Color.primary.opacity(0.4))
        .frame(width: 3, height: thumb)
        .offset(y: progress * (track - thumb))
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .padding(.top, DesignTokens.Spacing.xs)
      .padding(.bottom, DesignTokens.Spacing.xxs)
  }

  private func presetRow(_ preset: EQPreset) -> some View {
    Button {
      selection.select(preset)
    } label: {
      presetLabel(preset.name, selected: matchingBuiltIn == preset)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Apply \(preset.name) preset")
  }

  @ViewBuilder private func userPresetRow(_ preset: UserEQPreset) -> some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      Button {
        selection.select(preset.settings)
      } label: {
        presetLabel(
          preset.name, selected: matchingBuiltIn == nil && matchingUserPreset?.id == preset.id)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Apply \(preset.name) preset")
      Button {
        beginNaming(preset)
        isPresetListPresented = false
      } label: {
        Image(systemName: "pencil").font(.system(size: 10))
      }
      .buttonStyle(.plain).help("Rename preset")
      Button {
        bindings.actions.app.deletePreset(preset.id)
        isPresetListPresented = false
      } label: {
        Image(systemName: "trash").font(.system(size: 10))
      }
      .buttonStyle(.plain).help("Delete preset")
    }
  }

  private func presetLabel(_ name: String, selected: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DesignTokens.Colors.accentPrimary)
        .opacity(selected ? 1 : 0)
      Text(name).lineLimit(1)
      Spacer(minLength: 0)
    }
    .font(DesignTokens.Typography.pickerText)
    .padding(.horizontal, DesignTokens.Spacing.xs)
    .padding(.vertical, DesignTokens.Spacing.xxs)
    .contentShape(Rectangle())
  }

  private func beginNaming(_ preset: UserEQPreset?) {
    renamingPresetID = preset?.id
    presetName = preset?.name ?? ""
    isNamingPreset = true
  }
}
