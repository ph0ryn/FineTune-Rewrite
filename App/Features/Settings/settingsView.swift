import AppKit
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import KeyboardShortcuts
import SwiftUI

@MainActor
struct FineTuneSettingsView: View {
  let read: () -> SettingsSnapshot
  let actions: SettingsActions
  let updates: SettingsUpdateCapability
  @State private var tab: Tab = .general
  @State private var confirmingReset = false

  private enum Tab { case general, audio, shortcuts, updates, about }
  private var bindings: SettingsBindings { SettingsBindings(read: read, actions: actions) }

  var body: some View {
    let snapshot = read()
    VStack(spacing: 0) {
      if let error = snapshot.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
          .padding(DesignTokens.Spacing.sm)
      }
      TabView(selection: $tab) {
        general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
        audio.tabItem { Label("Audio", systemImage: "speaker.wave.2") }.tag(Tab.audio)
        Group {
          // Mounting General must not instantiate a global shortcut recorder.
          if tab == .shortcuts { shortcuts }
        }
        .tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(Tab.shortcuts)
        SettingsUpdatesView(capability: updates)
          .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag(Tab.updates)
        about.tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
      }
    }
    .frame(width: 720, height: 560)
    .background(WindowAppearanceBridge(appearance: snapshot.settings.appearance.nsAppearance))
    .preferredColorScheme(snapshot.settings.appearance.swiftUIColorScheme)
    .environment(\.appearancePreference, snapshot.settings.appearance)
    .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive, action: actions.resetAll)
    } message: {
      Text("This clears all saved volumes, EQ, and device routings. This cannot be undone.")
    }
  }

  private var general: some View {
    Form {
      Section("General") {
        Toggle("Launch at Login", isOn: bindings.field(\AppSettings.launchAtLogin))
          .help("Start FineTune when you log in")
        setting("Theme", description: "Match macOS, or lock to Light or Dark") {
          Picker("Theme", selection: bindings.field(\AppSettings.appearance)) {
            ForEach(AppearancePreference.allCases) { Text($0.description).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
        Toggle(
          "Device Disconnect Alerts", isOn: bindings.field(\AppSettings.showDeviceDisconnectAlerts)
        )
        .help("Show a notification when an audio device disconnects")
      }
      Section("Menu Bar") {
        setting("Icon Style", description: "How FineTune appears in your menu bar") {
          Picker("Icon Style", selection: bindings.field(\AppSettings.menuBarIconStyle)) {
            ForEach(MenuBarIconStyle.allCases) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
        setting("Popup Size", description: "Choose how much space the mixer uses") {
          Picker("Popup Size", selection: bindings.field(\AppSettings.popupSize)) {
            ForEach(MenuBarPopupSize.allCases) { Text($0.description).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
      }
      Section("Data") {
        setting("Reset All Settings", description: "Clear all volumes, EQ, and device routings") {
          Button("Reset", role: .destructive) { confirmingReset = true }
        }
      }
    }
    .formStyle(.grouped).controlSize(.small)
  }

  private var audio: some View {
    Form {
      Section("Volume") {
        setting(
          "Live Audio Processing",
          description: "macOS may ask for audio capture permission. Turn off to stop processing."
        ) {
          Toggle(
            "Live Audio Processing", isOn: bindings.field(\AppSettings.explicitUserCaptureEnabled)
          )
          .labelsHidden()
        }
        setting("Default Volume", description: "Initial volume for new apps") {
          HStack(spacing: DesignTokens.Spacing.sm) {
            Slider(value: bindings.defaultVolume, in: 0.1...1).frame(width: 230)
              .accessibilityLabel("Default app volume")
            VolumePercentageField(
              value: bindings.defaultVolume, range: 10...100, label: "Default volume percentage")
          }
        }
        Toggle("Loudness Compensation", isOn: bindings.unifiedLoudness)
          .help("Boost low frequencies at low volume")
      }
      Section("Devices") {
        Toggle("Lock Input Device", isOn: bindings.field(\AppSettings.lockInputDevice))
          .help("Prevent auto-switching when devices connect")
        setting("System Sounds", description: "Where alerts and effects play") {
          systemSoundsPicker
        }
        setting("Alert Volume", description: "Volume for alerts and notifications") {
          if let volume = bindings.alertVolume {
            HStack(spacing: DesignTokens.Spacing.sm) {
              Slider(value: volume, in: 0...1).frame(width: 230).accessibilityLabel("Alert volume")
              VolumePercentageField(value: volume, range: 0...100, label: "Alert volume percentage")
              if read().device.alertIsApplying { ProgressView().controlSize(.small) }
            }
            .disabled(read().device.alertIsApplying)
          } else {
            Text("Alert volume is unavailable.").foregroundStyle(.secondary)
          }
        }
        if let error = read().device.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped).controlSize(.small)
  }

  private var systemSoundsPicker: some View {
    let current = read().device
    return Picker("System Sounds", selection: bindings.systemSounds) {
      Text("System Default").tag(SettingsSystemSoundChoice.followDefault)
      ForEach(current.systemOutputOptions) { device in
        Text(device.name).tag(SettingsSystemSoundChoice.device(device.uid))
      }
      if let uid = current.systemOutputUID,
        !current.systemOutputOptions.contains(where: { $0.uid == uid })
      {
        Text("Unavailable (\(uid))").tag(SettingsSystemSoundChoice.device(uid)).disabled(true)
      } else if current.systemOutputUID == nil && !current.followsDefault {
        Text("Current output unavailable").tag(SettingsSystemSoundChoice.unavailable).disabled(true)
      }
    }
    .labelsHidden().fixedSize().disabled(!current.canSetSystemOutput)
  }

  private var shortcuts: some View {
    Form {
      Section("Volume") {
        setting(
          "Volume Step",
          description: "Used by media keys, configured hotkeys, and arrow keys in the mixer"
        ) {
          Picker("Volume Step", selection: bindings.field(\AppSettings.volumeHotkeyStep)) {
            ForEach(VolumeHotkeyStep.allCases) { Text($0.description).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
      }
      Section("Media Keys") {
        Toggle("Media Keys Control", isOn: bindings.field(\AppSettings.mediaKeyControlEnabled))
          .help("Use F11/F12 or volume keys to control FineTune")
        if !read().isAccessibilityTrusted {
          HStack {
            Text("Allow Accessibility access to control volume with media keys.")
              .font(DesignTokens.Typography.rowDescription)
            Spacer()
            Button("Allow Access", action: actions.requestAccessibility)
          }
        }
        if read().isMediaKeyOffline {
          HStack {
            Label("Media key control is offline.", systemImage: "exclamationmark.triangle")
            Spacer()
            Button("Try Again", action: actions.retryMediaKeys)
          }
        }
        if read().settings.mediaKeyControlEnabled && read().isAccessibilityTrusted {
          setting("HUD Style", description: "How the volume indicator appears") {
            Picker("HUD Style", selection: bindings.field(\AppSettings.hudStyle)) {
              ForEach(HUDStyle.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
          }
        }
      }
      Section("Hotkeys") {
        ForEach(ShortcutAction.allCases, id: \.self) { action in
          setting(action.displayName, description: shortcutDescription(action)) {
            KeyboardShortcuts.Recorder(
              for: .init(action.stableID),
              onChange: { actions.recordShortcut(action, $0.map(ShortcutCodable.from)) })
          }
        }
      }
    }
    .formStyle(.grouped).controlSize(.small)
  }

  private var about: some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      Spacer()
      Image(systemName: "waveform").font(.system(size: 64)).accessibilityHidden(true)
      Text("FineTune").font(.system(size: 22, weight: .semibold))
      if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
      {
        Text("Version \(version)").font(DesignTokens.Typography.percentage).foregroundStyle(
          .secondary)
      } else {
        Text("Development build").font(DesignTokens.Typography.rowDescription).foregroundStyle(
          .secondary)
      }
      Text("Independent rewrite · Original project by Ronit Singh")
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      Link(
        "Original FineTune", destination: URL(string: "https://github.com/ronitsingh10/FineTune")!)
      Link("GPL-3.0", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func setting<Content: View>(
    _ title: String, description: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: DesignTokens.Spacing.lg) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(title).font(DesignTokens.Typography.rowName)
        Text(description).font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
      Spacer(minLength: DesignTokens.Spacing.md)
      content()
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
  }

  private func shortcutDescription(_ action: ShortcutAction) -> String {
    switch action {
    case .togglePopup: "Show or hide the menu bar popup"
    case .targetAppVolumeUp: "Raise volume for the app playing audio"
    case .targetAppVolumeDown: "Lower volume for the app playing audio"
    case .targetAppMuteToggle: "Mute or unmute the app playing audio"
    }
  }
}
