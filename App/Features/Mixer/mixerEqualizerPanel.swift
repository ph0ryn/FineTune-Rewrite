import FineTuneDomain
import SwiftUI

@MainActor
struct MixerEqualizerPanel: View {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  @State private var isNamingPreset = false
  @State private var presetName = ""
  @State private var renamingPresetID: UUID?

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

  private var presetMenu: some View {
    Menu(matchingBuiltIn?.name ?? matchingUserPreset?.name ?? "Custom") {
      ForEach(EQPreset.Category.allCases) { category in
        Menu(category.rawValue) {
          ForEach(EQPreset.presets(for: category)) { preset in
            Button {
              bindings.applyPreset(preset, to: app)
            } label: {
              presetLabel(preset.name, selected: matchingBuiltIn == preset)
            }
          }
        }
      }
      let presets = bindings.snapshot.userPresets
      if !presets.isEmpty {
        Section("My Presets") {
          ForEach(presets) { preset in
            Menu {
              Button("Apply") { bindings.applyCurve(preset.settings, to: app) }
              Button("Rename…") { beginNaming(preset) }
              Button("Delete", role: .destructive) { bindings.actions.app.deletePreset(preset.id) }
            } label: {
              presetLabel(
                preset.name, selected: matchingBuiltIn == nil && matchingUserPreset?.id == preset.id
              )
            }
          }
        }
      }
    }
    .font(DesignTokens.Typography.pickerText)
    .fixedSize()
    .accessibilityLabel("EQ preset for \(app.name)")
  }

  @ViewBuilder private func presetLabel(_ name: String, selected: Bool) -> some View {
    if selected { Label(name, systemImage: "checkmark") } else { Text(name) }
  }

  private func beginNaming(_ preset: UserEQPreset?) {
    renamingPresetID = preset?.id
    presetName = preset?.name ?? ""
    isNamingPreset = true
  }
}
