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
  var generalCopy = SettingsGeneralCopy()
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
        // The tabItem must attach to the mounted Form itself: a Group whose conditional
        // content is empty renders no tab item at all on current SwiftUI, hiding Shortcuts.
        // Laziness still holds because TabView instantiates the recorder NSViews only when
        // this tab becomes selected; the General tab never creates a recorder control.
        shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(Tab.shortcuts)
        SettingsUpdatesView(capability: updates)
          .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag(Tab.updates)
        SettingsAboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
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
        setting(generalCopy.launchAtLoginTitle, description: generalCopy.launchAtLoginDescription) {
          Toggle(generalCopy.launchAtLoginTitle, isOn: bindings.field(\AppSettings.launchAtLogin))
            .labelsHidden()
        }
        setting(generalCopy.themeTitle, description: generalCopy.themeDescription) {
          Picker(generalCopy.themeTitle, selection: bindings.field(\AppSettings.appearance)) {
            ForEach(AppearancePreference.allCases) { Text($0.description).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
        setting(
          generalCopy.disconnectAlertsTitle,
          description: generalCopy.disconnectAlertsDescription
        ) {
          Toggle(
            generalCopy.disconnectAlertsTitle,
            isOn: bindings.field(\AppSettings.showDeviceDisconnectAlerts)
          )
          .labelsHidden()
        }
      }
      Section("Menu Bar") {
        setting("Icon Style", description: "How FineTune appears in your menu bar") {
          Picker("Icon Style", selection: bindings.field(\AppSettings.menuBarIconStyle)) {
            ForEach(MenuBarIconStyle.allCases) { Text($0.rawValue).tag($0) }
          }
          .labelsHidden().fixedSize()
        }
        setting(
          "Popup Size",
          description: "Smaller fits more on screen; larger leaves more breathing room."
        ) {
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
        setting("Loudness Compensation", description: "Boost low frequencies at low volume") {
          Toggle("Loudness Compensation", isOn: bindings.unifiedLoudness).labelsHidden()
        }
      }
      Section("Devices") {
        setting("Lock Input Device", description: "Prevent auto-switching when devices connect") {
          Toggle("Lock Input Device", isOn: bindings.field(\AppSettings.lockInputDevice))
            .labelsHidden()
        }
        setting("System Sounds", description: "Where alerts and effects play") {
          systemSoundsPicker
        }
        setting("Alert Volume", description: "Volume for alerts and notifications") {
          if let volume = bindings.alertVolume {
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
              HStack(spacing: DesignTokens.Spacing.sm) {
                Slider(value: volume, in: 0...1).frame(width: 230)
                  .accessibilityLabel("Alert volume")
                VolumePercentageField(
                  value: volume, range: 0...100, label: "Alert volume percentage")
                if read().device.alertIsApplying { ProgressView().controlSize(.small) }
              }
              .disabled(read().device.alertIsApplying || read().device.alertVolumeSilenced)
              if read().device.alertVolumeSilenced {
                Text("Alerts are silenced while the System Sounds device is muted.")
                  .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
              }
            }
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
        setting(
          "Media Keys Control", description: "Use F11/F12 (or volume keys) to control FineTune"
        ) {
          Toggle("Media Keys Control", isOn: bindings.field(\AppSettings.mediaKeyControlEnabled))
            .labelsHidden()
        }
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
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
              Label("Media key control is offline.", systemImage: "exclamationmark.triangle")
              Text(
                "The media-key event tap is unavailable. This can happen after sleep or wake, or a main-thread stall. Try Again to reinstall it."
              )
              .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
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

@MainActor
struct SettingsAboutView: View {
  var metadata: SettingsAboutPresentation = .current
  var appIcon: NSImage? = NSApp?.applicationIconImage
  var copy = SettingsAboutCopy()

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      Spacer()
      if let appIcon {
        Image(nsImage: appIcon).resizable().interpolation(.high).frame(width: 96, height: 96)
          .accessibilityLabel(copy.appIconLabel)
      } else {
        Label(copy.appIconUnavailable, systemImage: "app")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
      Text(copy.title).font(.system(size: 22, weight: .semibold))
      Text(metadata.versionDescription).font(DesignTokens.Typography.percentage)
        .foregroundStyle(.secondary)
      Text(copy.independentRewrite)
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      Spacer()
      Link(copy.starLabel, destination: copy.starURL)
      HStack(spacing: DesignTokens.Spacing.xs) {
        Link(copy.licenseLabel, destination: copy.licenseURL)
        Text("·")
        Text(metadata.copyright)
      }
      .font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
      .padding(.bottom, DesignTokens.Spacing.lg)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
