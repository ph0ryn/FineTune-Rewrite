import AppKit
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import KeyboardShortcuts
import SwiftUI

enum SettingsTab: CaseIterable, Hashable {
  case general, audio, shortcuts, updates, about

  var title: String {
    switch self {
    case .general: "General"
    case .audio: "Audio"
    case .shortcuts: "Shortcuts"
    case .updates: "Updates"
    case .about: "About"
    }
  }
}

@MainActor
struct FineTuneSettingsView: View {
  let read: () -> SettingsSnapshot
  let actions: SettingsActions
  let updates: SettingsUpdateCapability
  var generalCopy = SettingsGeneralCopy()
  @State private var tab: SettingsTab = .general
  @State private var confirmingReset = false

  var body: some View {
    let snapshot = read()
    let bindings = SettingsBindings(snapshot: snapshot, actions: actions, readFresh: read)
    VStack(spacing: 0) {
      tabBar
      Divider()
      if let error = snapshot.error {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(error).fixedSize(horizontal: false, vertical: true)
        }
        .font(DesignTokens.Typography.rowDescription)
        .foregroundStyle(.orange)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
      }
      content(for: tab, snapshot: snapshot, bindings: bindings)
    }
    .frame(width: 720, height: 560)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(WindowAppearanceBridge(appearance: snapshot.settings.appearance.nsAppearance))
    .preferredColorScheme(snapshot.settings.appearance.swiftUIColorScheme)
    .environment(\.appearancePreference, snapshot.settings.appearance)
    .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive, action: actions.resetAll)
    } message: {
      Text("This clears all saved volumes, EQ, and device routings. This cannot be undone.")
    }
  }

  private var tabBar: some View {
    SettingsTabSelector(selection: $tab)
      .frame(height: 36)
      .padding(.horizontal, DesignTokens.Spacing.lg)
      .padding(.top, DesignTokens.Spacing.sm)
  }

  @ViewBuilder
  private func content(
    for tab: SettingsTab, snapshot: SettingsSnapshot, bindings: SettingsBindings
  ) -> some View {
    switch tab {
    case .general: general(bindings: bindings)
    case .audio: audio(snapshot: snapshot, bindings: bindings)
    case .shortcuts: shortcuts(snapshot: snapshot, bindings: bindings)
    case .updates: SettingsUpdatesView(capability: updates)
    case .about: SettingsAboutView()
    }
  }

  private func general(bindings: SettingsBindings) -> some View {
    SettingsScrollView {
      SettingsSection("General") {
        setting(generalCopy.launchAtLoginTitle, description: generalCopy.launchAtLoginDescription) {
          SettingsNativeToggle(
            isOn: bindings.field(\AppSettings.launchAtLogin),
            title: generalCopy.launchAtLoginTitle)
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
          SettingsNativeToggle(
            isOn: bindings.field(\AppSettings.showDeviceDisconnectAlerts),
            title: generalCopy.disconnectAlertsTitle)
        }
      }
      SettingsSection("Menu Bar") {
        setting("Icon Style", description: "How FineTune-Rewrite appears in your menu bar") {
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
      SettingsSection("Data") {
        setting("Reset All Settings", description: "Clear all volumes, EQ, and device routings") {
          Button("Reset", role: .destructive) { confirmingReset = true }
        }
      }
    }
  }

  private func audio(snapshot: SettingsSnapshot, bindings: SettingsBindings) -> some View {
    SettingsScrollView {
      SettingsSection("Volume") {
        setting(
          "Live Audio Processing",
          description: "macOS may ask for audio capture permission. Turn off to stop processing."
        ) {
          SettingsNativeToggle(
            isOn: bindings.field(\AppSettings.explicitUserCaptureEnabled),
            title: "Live Audio Processing")
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
          SettingsNativeToggle(isOn: bindings.unifiedLoudness, title: "Loudness Compensation")
        }
      }
      SettingsSection("Devices") {
        setting("Lock Input Device", description: "Prevent auto-switching when devices connect") {
          SettingsNativeToggle(
            isOn: bindings.field(\AppSettings.lockInputDevice), title: "Lock Input Device")
        }
        setting("System Sounds", description: "Where alerts and effects play") {
          systemSoundsPicker(snapshot: snapshot, bindings: bindings)
        }
        setting("Alert Volume", description: "Volume for alerts and notifications") {
          if let volume = bindings.alertVolume {
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
              HStack(spacing: DesignTokens.Spacing.sm) {
                Slider(value: volume, in: 0...1).frame(width: 230)
                  .accessibilityLabel("Alert volume")
                VolumePercentageField(
                  value: volume, range: 0...100, label: "Alert volume percentage")
                if snapshot.device.alertIsApplying { ProgressView().controlSize(.small) }
              }
              .disabled(snapshot.device.alertIsApplying || snapshot.device.alertVolumeSilenced)
              if snapshot.device.alertVolumeSilenced {
                Text("Alerts are silenced while the System Sounds device is muted.")
                  .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
              }
            }
          } else {
            Text("Alert volume is unavailable.").foregroundStyle(.secondary)
          }
        }
        if let error = snapshot.device.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
        }
      }
    }
  }

  private func systemSoundsPicker(
    snapshot: SettingsSnapshot, bindings: SettingsBindings
  ) -> some View {
    let current = snapshot.device
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

  private func shortcuts(
    snapshot: SettingsSnapshot, bindings: SettingsBindings
  ) -> some View {
    SettingsScrollView {
      SettingsSection("Volume") {
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
      SettingsSection("Media Keys") {
        setting(
          "Media Keys Control",
          description: "Use F11/F12 (or volume keys) to control FineTune-Rewrite"
        ) {
          SettingsNativeToggle(
            isOn: bindings.field(\AppSettings.mediaKeyControlEnabled), title: "Media Keys Control")
        }
        if !snapshot.isAccessibilityTrusted {
          HStack {
            Text("Allow Accessibility access to control volume with media keys.")
              .font(DesignTokens.Typography.rowDescription)
            Spacer()
            Button("Allow Access", action: actions.requestAccessibility)
          }
        }
        if snapshot.isMediaKeyOffline {
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
        if snapshot.settings.mediaKeyControlEnabled && snapshot.isAccessibilityTrusted {
          setting("HUD Style", description: "How the volume indicator appears") {
            Picker("HUD Style", selection: bindings.field(\AppSettings.hudStyle)) {
              ForEach(HUDStyle.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
          }
        }
      }
      SettingsSection("Hotkeys") {
        ForEach(ShortcutAction.allCases, id: \.self) { action in
          setting(action.displayName, description: shortcutDescription(action)) {
            KeyboardShortcuts.Recorder(
              for: .init(action.stableID),
              onChange: { actions.recordShortcut(action, $0.map(ShortcutCodable.from)) })
          }
        }
      }
    }
  }

  private func setting<Content: View>(
    _ title: String, description: String, @ViewBuilder content: () -> Content
  ) -> some View {
    SettingsRow(title, description: description) { content() }
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
      HStack(spacing: DesignTokens.Spacing.md) {
        Link(copy.rewriteLabel, destination: copy.rewriteURL)
        Text("·")
        Link(copy.originalLabel, destination: copy.originalURL)
      }
      HStack(spacing: DesignTokens.Spacing.xs) {
        Link(copy.licenseLabel, destination: copy.licenseURL)
        Text("·")
        Link(copy.noticesLabel, destination: copy.noticesURL)
        Text("·")
        Text(metadata.copyright)
      }
      .font(DesignTokens.Typography.caption).foregroundStyle(.tertiary)
      .padding(.bottom, DesignTokens.Spacing.lg)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
