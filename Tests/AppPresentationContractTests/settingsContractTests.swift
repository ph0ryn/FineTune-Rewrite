// No-render presentation contracts: exact production copy, formatting, and settings bindings.
// This suite constructs no application, window, view, bitmap, event or Vision request and runs no
// loop or sleep. It is a source-review convention, not a compiler-enforced import boundary: the
// FineTune module still links SwiftUI/AppKit for the views it contains.
import FineTuneDomain
import Foundation
import Testing

@testable import FineTune

@Suite("Presentation contract: settings copy, formatting, and bindings")
@MainActor
struct SettingsContractTests {
  @Test("The General tab renders exactly these preference strings")
  func generalCopy() {
    let copy = SettingsGeneralCopy()
    #expect(copy.launchAtLoginTitle == "Launch at Login")
    #expect(copy.launchAtLoginDescription == "Start FineTune-Rewrite when you log in")
    #expect(copy.themeTitle == "Theme")
    #expect(copy.themeDescription == "Match macOS, or lock to Light or Dark")
    #expect(copy.disconnectAlertsTitle == "Device Disconnect Alerts")
    #expect(
      copy.disconnectAlertsDescription == "Show notification when an audio device disconnects")
  }

  @Test("About renders exactly these project, license and icon strings and destinations")
  func aboutCopy() {
    let copy = SettingsAboutCopy()
    #expect(copy.title == "FineTune-Rewrite")
    #expect(copy.appIconLabel == "FineTune-Rewrite app icon")
    #expect(copy.appIconUnavailable == "App icon unavailable")
    #expect(copy.independentRewrite == "Independent rewrite of FineTune by Ronit Singh")
    #expect(copy.rewriteLabel == "FineTune-Rewrite")
    #expect(copy.rewriteURL == URL(string: "https://github.com/ph0ryn/FineTune-Rewrite")!)
    #expect(copy.originalLabel == "FineTune (Original)")
    #expect(copy.originalURL == URL(string: "https://github.com/ronitsingh10/FineTune")!)
    #expect(copy.licenseLabel == "LICENSE")
    #expect(
      copy.licenseURL
        == URL(string: "https://github.com/ph0ryn/FineTune-Rewrite/blob/main/LICENSE")!)
    #expect(copy.noticesLabel == "THIRD_PARTY_NOTICES")
    #expect(
      copy.noticesURL
        == URL(
          string:
            "https://github.com/ph0ryn/FineTune-Rewrite/blob/main/App/Resources/THIRD_PARTY_NOTICES.txt"
        )!)
  }
  @Test("Missing About metadata formats itself instead of borrowing a shipped version")
  func aboutMissingMetadataFormatting() {
    let metadata = SettingsAboutPresentation(version: nil, build: nil, year: 2028)
    #expect(metadata.versionDescription == "Version unavailable (build unavailable)")
    #expect(metadata.copyright == "© 2026–2028 Yuta Fudaba")
  }

  @Test("Copyright never prints a reversed year range")
  func copyrightYearRange() {
    func copyright(_ year: Int) -> String {
      SettingsAboutPresentation(version: "1", build: "1", year: year).copyright
    }
    #expect(copyright(2025) == "© 2026 Yuta Fudaba")
    #expect(copyright(2026) == "© 2026 Yuta Fudaba")
    #expect(copyright(2027) == "© 2026–2027 Yuta Fudaba")
  }

  @Test("Updates renders exactly these section, state and version-line strings")
  func updatesCopy() {
    let copy = SettingsUpdatesCopy()
    #expect(copy.sectionTitle == "Software Updates")
    #expect(copy.automaticUpdatesTitle == "Automatic updates")
    #expect(copy.automaticUpdatesDescription == "Check for new versions automatically")
    #expect(copy.notConfigured == "Not configured")
    #expect(copy.lastCheckedTitle == "Last checked")
    #expect(copy.neverChecked == "Never checked")
    #expect(copy.checkNow == "Check Now")
    #expect(copy.unavailable == "Updates are unavailable in this build.")
    #expect(copy.versionLinePrefix(version: "8.1") == "Version 8.1 ·")
    #expect(
      "\(copy.versionLinePrefix(version: "8.1")) \(copy.neverChecked)"
        == "Version 8.1 · Never checked")
  }

  @Test("Changing a field preserves unrelated preferences updated after the binding was created")
  func fieldBindingUsesLatestSettings() {
    let source = SettingsTestSource()
    let theme = source.bindings.field(\AppSettings.appearance)
    source.snapshot.settings.popupSize = .spacious
    source.snapshot.settings.volumeHotkeyStep = .extraFine
    theme.wrappedValue = .dark
    #expect(source.snapshot.settings.appearance == .dark)
    #expect(source.snapshot.settings.popupSize == .spacious)
    #expect(source.snapshot.settings.volumeHotkeyStep == .extraFine)
    #expect(source.events == ["settings"])
  }

  @Test("A previously created binding also reads externally changed preferences")
  func fieldGetterRemainsLive() {
    let source = SettingsTestSource()
    let enabled = source.bindings.field(\AppSettings.mediaKeyControlEnabled)
    source.snapshot.settings.mediaKeyControlEnabled = false
    #expect(!enabled.wrappedValue)
    #expect(source.events.isEmpty)
  }

  @Test("Unified loudness writes both settings while preserving current unrelated fields")
  func unifiedLoudnessBinding() {
    let source = SettingsTestSource()
    source.snapshot.settings.loudnessCompensationEnabled = true
    source.snapshot.settings.loudnessEqualizationEnabled = false
    let unified = source.bindings.unifiedLoudness
    #expect(!unified.wrappedValue)
    source.snapshot.settings.appearance = .light
    unified.wrappedValue = true
    #expect(source.snapshot.settings.loudnessCompensationEnabled)
    #expect(source.snapshot.settings.loudnessEqualizationEnabled)
    #expect(source.snapshot.settings.appearance == .light)
    unified.wrappedValue = false
    #expect(!source.snapshot.settings.loudnessCompensationEnabled)
    #expect(!source.snapshot.settings.loudnessEqualizationEnabled)
  }

  @Test("The saved default-volume preference retains the original direct scalar editing")
  func defaultVolumeBinding() {
    let source = SettingsTestSource()
    source.snapshot.settings.defaultNewAppVolume = 0.25
    let slider = source.bindings.defaultVolume
    #expect(slider.wrappedValue == 0.25)
    slider.wrappedValue = 0.8
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.8)
  }

  @Test("Typed default-volume percentages keep the original ten-percent lower bound")
  func editableDefaultPercentage() {
    let source = SettingsTestSource()
    let field = VolumePercentageField(
      value: source.bindings.defaultVolume, range: 10...100, label: "Default volume")
    field.boundedValue.wrappedValue = 0.02
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.1)
    field.boundedValue.wrappedValue = 0.6
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.6)
  }

  @Test("Shortcut recording and clearing forward the action and value without global registration")
  func shortcutActionsAreExplicit() {
    let source = SettingsTestSource()
    let value = ShortcutCodable(keyCode: 42, modifiers: 256)
    source.actions.recordShortcut(.togglePopup, value)
    #expect(source.lastShortcutAction == .togglePopup)
    #expect(source.lastShortcut == value)
    source.actions.recordShortcut(.targetAppVolumeUp, nil)
    #expect(source.lastShortcutAction == .targetAppVolumeUp)
    #expect(source.lastShortcut == nil)
    #expect(source.events == ["shortcut", "shortcut"])
  }

  @Test("An unavailable alert value never exposes a fabricated zero slider")
  func alertAvailabilityIsExplicit() throws {
    let source = SettingsTestSource()
    #expect(source.bindings.alertVolume == nil)
    source.snapshot.device.canSetAlertVolume = true
    #expect(source.bindings.alertVolume == nil)
    source.snapshot.device.alertVolume = 0.4
    let binding = try #require(source.bindings.alertVolume)
    source.snapshot.device.alertVolume = 0.7
    #expect(abs(binding.wrappedValue - 0.7) < 0.000_001)
    binding.wrappedValue = 0.3
    #expect(source.events == ["alert:0.3"])
    #expect(source.snapshot.device.alertVolume == 0.7)
  }

  @Test("System sounds preserve follow-default intent independently of observed output")
  func systemSoundsBindingSeparatesIntent() {
    let source = SettingsTestSource()
    #expect(source.bindings.systemSounds.wrappedValue == .followDefault)
    source.snapshot.device.followsDefault = false
    #expect(source.bindings.systemSounds.wrappedValue == .unavailable)
    source.snapshot.device.systemOutputUID = "observed-output"
    #expect(source.bindings.systemSounds.wrappedValue == .device("observed-output"))
    source.bindings.systemSounds.wrappedValue = .device("requested-output")
    source.bindings.systemSounds.wrappedValue = .followDefault
    #expect(source.events == ["system-output:requested-output", "system-follow"])
    #expect(source.snapshot.device.systemOutputUID == "observed-output")
  }

  @Test("An available update service supplies live values and explicit actions")
  func updatesUseLiveBindings() {
    var snapshot = SettingsUpdatePresentation(
      automaticallyChecks: true, lastChecked: nil, isChecking: false, error: nil)
    var requests: [String] = []
    let actions = SettingsUpdateActions(
      checkNow: { requests.append("check") },
      setAutomaticChecks: { requests.append("auto:\($0)") })
    let bindings = SettingsUpdateBindings(read: { snapshot }, actions: actions)
    snapshot.automaticallyChecks = false
    #expect(!bindings.automaticChecks.wrappedValue)
    bindings.automaticChecks.wrappedValue = true
    actions.checkNow()
    #expect(requests == ["auto:true", "check"])
    #expect(!snapshot.automaticallyChecks)
  }

  @Test("Software volume override toggle visibility covers tier, direction and capability")
  func inspectorShouldShowToggleMatrix() {
    let tiers: [VolumeControlTier?] = [.hardware, .ddc, .software, nil]
    for autoTier in tiers {
      for isInput in [false, true] {
        for allowsVolumeOverride in [false, true] {
          for hasOverrideAction in [false, true] {
            let expected =
              autoTier != nil && autoTier != .software && !isInput && allowsVolumeOverride
              && hasOverrideAction
            #expect(
              DeviceDetailSheet.shouldShowToggle(
                autoTier: autoTier, isInput: isInput,
                allowsVolumeOverride: allowsVolumeOverride,
                hasOverrideAction: hasOverrideAction) == expected)
          }
        }
      }
    }
  }

  @Test("Updates Check Now availability reflects capability and busy state")
  func updatesCanCheckNowStates() {
    let unavailable = SettingsUpdatesView(
      capability: .unavailable(reason: "No signed rewrite release feed is configured."),
      version: "8.1")
    #expect(!unavailable.canCheckNow)

    var snapshot = SettingsUpdatePresentation(
      automaticallyChecks: true, lastChecked: nil, isChecking: false, error: nil)
    let available = SettingsUpdatesView(
      capability: .available(
        read: { snapshot },
        actions: SettingsUpdateActions(checkNow: {}, setAutomaticChecks: { _ in })),
      version: "8.1")
    #expect(available.canCheckNow)
    snapshot.isChecking = true
    #expect(!available.canCheckNow)
  }
}
