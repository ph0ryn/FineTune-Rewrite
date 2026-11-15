// No-render presentation contracts: exact production copy and formatting values only.
// This suite constructs no application, window, view, bitmap, event or Vision request and runs no
// loop or sleep. It is a source-review convention, not a compiler-enforced import boundary: the
// FineTune module still links SwiftUI/AppKit for the views it contains.
import FineTuneDomain
import Foundation
import Testing

@testable import FineTune

@Suite("Presentation contract: settings copy and formatting")
struct SettingsContractTests {
  @Test("The General tab renders exactly these preference strings")
  func generalCopy() {
    let copy = SettingsGeneralCopy()
    #expect(copy.launchAtLoginTitle == "Launch at Login")
    #expect(copy.launchAtLoginDescription == "Start FineTune when you log in")
    #expect(copy.themeTitle == "Theme")
    #expect(copy.themeDescription == "Match macOS, or lock to Light or Dark")
    #expect(copy.disconnectAlertsTitle == "Device Disconnect Alerts")
    #expect(
      copy.disconnectAlertsDescription == "Show notification when an audio device disconnects")
  }

  @Test("About renders exactly these project, license and icon strings and destinations")
  func aboutCopy() {
    let copy = SettingsAboutCopy()
    #expect(copy.title == "FineTune")
    #expect(copy.appIconLabel == "FineTune app icon")
    #expect(copy.appIconUnavailable == "App icon unavailable")
    #expect(copy.independentRewrite == "Independent rewrite · Original project by Ronit Singh")
    #expect(copy.starLabel == "Star on GitHub")
    #expect(copy.starURL == URL(string: "https://github.com/ronitsingh10/FineTune")!)
    #expect(copy.licenseLabel == "GPL-3.0")
    #expect(copy.licenseURL == URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
  }

  @Test("Missing About metadata formats itself instead of borrowing a shipped version")
  func aboutMissingMetadataFormatting() {
    let metadata = SettingsAboutPresentation(version: nil, build: nil, year: 2028)
    #expect(metadata.versionDescription == "Version unavailable (build unavailable)")
    #expect(metadata.copyright == "© 2026–2028 Ronit Singh")
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
}
