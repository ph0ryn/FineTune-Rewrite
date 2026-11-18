import FineTuneDomain
import Foundation
import Testing

@Suite("Domain: AppSettings defaults, Codable round-trip, and hotkey steps")
struct AppSettingsCodableTests {
  @Test("Only an explicit saved wish enables restoration; missing data never grants access")
  func defaultsOffAndRoundTripsExplicitWish() throws {
    let decoder = JSONDecoder()
    let missing = try decoder.decode(AppSettings.self, from: Data("{}".utf8))
    let defaults = AppSettings()
    #expect(!defaults.explicitUserCaptureEnabled)
    #expect(!missing.explicitUserCaptureEnabled)
    #expect(missing == defaults)

    var enabled = missing
    enabled.explicitUserCaptureEnabled = true
    let data = try JSONEncoder().encode(enabled)
    #expect(try decoder.decode(AppSettings.self, from: data).explicitUserCaptureEnabled)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["explicitUserCaptureEnabled"] as? Bool == true)
    #expect(object["sessionID"] == nil)
    #expect(object["authorizationStatus"] == nil)

    let malformed = Data(#"{"explicitUserCaptureEnabled":"yes"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try decoder.decode(AppSettings.self, from: malformed)
    }
  }

  @Test("Unknown JSON keys are ignored and all AppSettings fields round-trip")
  func fullRoundTripAndUnknownKeysIgnored() throws {
    let jsonWithUnknown = Data(#"{"unknownFutureKey": 123, "defaultNewAppVolume": 0.4}"#.utf8)
    let partial = try JSONDecoder().decode(AppSettings.self, from: jsonWithUnknown)
    #expect(partial.defaultNewAppVolume == 0.4)
    #expect(partial.lockInputDevice)
    #expect(partial.mediaKeyControlEnabled)

    var modified = AppSettings()
    modified.launchAtLogin = true
    modified.explicitUserCaptureEnabled = true
    modified.menuBarIconStyle = .waveform
    modified.defaultNewAppVolume = 0.65
    modified.lockInputDevice = false
    modified.showDeviceDisconnectAlerts = false
    modified.setUnifiedLoudnessEnabled(true)
    modified.hudStyle = .classic
    modified.mediaKeyControlEnabled = false
    modified.volumeHotkeyStep = .extraFine
    modified.customShortcuts = ["togglePopup": ShortcutCodable(keyCode: 49, modifiers: 256)]
    modified.appearance = .dark
    modified.popupSize = .spacious

    let encoded = try JSONEncoder().encode(modified)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
    #expect(decoded == modified)
  }

  @Test("setUnifiedLoudnessEnabled keeps both loudness flags synchronized")
  func unifiedLoudnessSync() {
    var settings = AppSettings()
    settings.setUnifiedLoudnessEnabled(true)
    #expect(settings.loudnessCompensationEnabled && settings.loudnessEqualizationEnabled)
    settings.setUnifiedLoudnessEnabled(false)
    #expect(!settings.loudnessCompensationEnabled && !settings.loudnessEqualizationEnabled)
  }

  @Test("VolumeHotkeyStep slider deltas match exact 1/8..1/64 fractions")
  func hotkeyStepDeltas() {
    #expect(VolumeHotkeyStep.coarse.sliderDelta == 1.0 / 8.0)
    #expect(VolumeHotkeyStep.normal.sliderDelta == 1.0 / 16.0)
    #expect(VolumeHotkeyStep.fine.sliderDelta == 1.0 / 32.0)
    #expect(VolumeHotkeyStep.extraFine.sliderDelta == 1.0 / 64.0)
  }
}
