import FineTuneDomain
import Foundation
import Testing

// MARK: - AppearancePreference Codable

@Suite("Compat: AppearancePreference — Codable round-trip")
struct UpstreamAppearancePreferenceCodableTests {
  @Test("All cases round-trip through JSON as their raw String value")
  func roundTripAllCases() throws {
    for preference in AppearancePreference.allCases {
      let data = try JSONEncoder().encode(preference)
      let decoded = try JSONDecoder().decode(AppearancePreference.self, from: data)
      #expect(decoded == preference)
    }
  }

  @Test("system encodes as \"system\"")
  func systemRawEncoding() throws {
    let data = try JSONEncoder().encode(AppearancePreference.system)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"system\"")
  }

  @Test("light encodes as \"light\"")
  func lightRawEncoding() throws {
    let data = try JSONEncoder().encode(AppearancePreference.light)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"light\"")
  }

  @Test("dark encodes as \"dark\"")
  func darkRawEncoding() throws {
    let data = try JSONEncoder().encode(AppearancePreference.dark)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"dark\"")
  }

  @Test("AppearancePreference.allCases has exactly 3 entries")
  func allCasesCount() {
    #expect(AppearancePreference.allCases.count == 3)
  }

  @Test("id property matches rawValue")
  func idMatchesRawValue() {
    for preference in AppearancePreference.allCases {
      #expect(preference.id == preference.rawValue)
    }
  }

  @Test("AppSettings.appearance defaults to .system")
  func appSettingsAppearanceDefault() {
    let settings = AppSettings()
    #expect(settings.appearance == .system)
  }

  @Test("AppSettings with appearance=.light round-trips through JSON")
  func appSettingsAppearanceLightRoundTrip() throws {
    var settings = AppSettings()
    settings.appearance = .light
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.appearance == .light)
  }

  @Test("AppSettings with appearance=.dark round-trips through JSON")
  func appSettingsAppearanceDarkRoundTrip() throws {
    var settings = AppSettings()
    settings.appearance = .dark
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.appearance == .dark)
  }

  @Test("Decoding AppSettings without appearance key produces .system default")
  func missingAppearanceProducesSystemDefault() throws {
    let json = """
      {
        "launchAtLogin": false,
        "menuBarIconStyle": "Default",
        "defaultNewAppVolume": 1.0,
        "lockInputDevice": true,
        "showDeviceDisconnectAlerts": true,
        "hudStyle": "tahoe",
        "mediaKeyControlEnabled": true
      }
      """
    let data = Data(json.utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.appearance == .system)
  }
}

// MARK: - HUDStyle Codable

@Suite("Compat: HUDStyle — Codable round-trip")
struct UpstreamHUDStyleCodableTests {
  @Test("All cases round-trip through JSON as their raw String value")
  func roundTripAllCases() throws {
    for style in HUDStyle.allCases {
      let data = try JSONEncoder().encode(style)
      let decoded = try JSONDecoder().decode(HUDStyle.self, from: data)
      #expect(decoded == style)
    }
  }

  @Test("tahoe encodes as \"tahoe\"")
  func tahoeRawEncoding() throws {
    let data = try JSONEncoder().encode(HUDStyle.tahoe)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"tahoe\"")
  }

  @Test("classic encodes as \"classic\"")
  func classicRawEncoding() throws {
    let data = try JSONEncoder().encode(HUDStyle.classic)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"classic\"")
  }

  @Test("HUDStyle.allCases has exactly 2 entries")
  func allCasesCount() {
    #expect(HUDStyle.allCases.count == 2)
  }

  @Test("id property matches rawValue")
  func idMatchesRawValue() {
    for style in HUDStyle.allCases {
      #expect(style.id == style.rawValue)
    }
  }

  @Test("AppSettings.hudStyle defaults to .tahoe")
  func appSettingsHUDStyleDefault() {
    let settings = AppSettings()
    #expect(settings.hudStyle == .tahoe)
  }

  @Test("AppSettings.mediaKeyControlEnabled defaults to true")
  func appSettingsMediaKeyControlDefault() {
    let settings = AppSettings()
    #expect(settings.mediaKeyControlEnabled == true)
  }

  @Test("AppSettings with hudStyle=classic round-trips through JSON")
  func appSettingsHUDStyleRoundTrip() throws {
    var settings = AppSettings()
    settings.hudStyle = .classic
    settings.mediaKeyControlEnabled = false
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.hudStyle == .classic)
    #expect(decoded.mediaKeyControlEnabled == false)
  }

  @Test("Decoding AppSettings without hudStyle key produces .tahoe default")
  func missingHUDStyleProducesDefault() throws {
    let json = """
      {
        "launchAtLogin": false,
        "menuBarIconStyle": "Default",
        "defaultNewAppVolume": 1.0,
        "lockInputDevice": true,
        "showDeviceDisconnectAlerts": true
      }
      """
    let data = Data(json.utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.hudStyle == .tahoe)
    #expect(decoded.mediaKeyControlEnabled == true)
  }
}

// MARK: - MenuBarIconStyle

@Suite("Compat: MenuBarIconStyle — Enumeration")
struct UpstreamMenuBarIconStyleTests {
  @Test("allCases has 5 styles")
  func allCasesCount() {
    #expect(MenuBarIconStyle.allCases.count == 5)
  }

  @Test("Round-trip through JSON Codable")
  func codableRoundTrip() throws {
    for style in MenuBarIconStyle.allCases {
      let data = try JSONEncoder().encode(style)
      let decoded = try JSONDecoder().decode(MenuBarIconStyle.self, from: data)
      #expect(decoded == style)
    }
  }
}

// MARK: - MenuBarPopupSize Codable

@Suite("Compat: MenuBarPopupSize — Codable round-trip")
struct UpstreamMenuBarPopupSizeCodableTests {
  @Test("All cases round-trip through JSON as their raw String value")
  func roundTripAllCases() throws {
    for size in MenuBarPopupSize.allCases {
      let data = try JSONEncoder().encode(size)
      let decoded = try JSONDecoder().decode(MenuBarPopupSize.self, from: data)
      #expect(decoded == size)
    }
  }

  @Test("compact encodes as \"compact\"")
  func compactRawEncoding() throws {
    let data = try JSONEncoder().encode(MenuBarPopupSize.compact)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"compact\"")
  }

  @Test("comfortable encodes as \"comfortable\"")
  func comfortableRawEncoding() throws {
    let data = try JSONEncoder().encode(MenuBarPopupSize.comfortable)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"comfortable\"")
  }

  @Test("spacious encodes as \"spacious\"")
  func spaciousRawEncoding() throws {
    let data = try JSONEncoder().encode(MenuBarPopupSize.spacious)
    let s = String(data: data, encoding: .utf8)
    #expect(s == "\"spacious\"")
  }

  @Test("AppSettings.popupSize defaults to .comfortable when key is missing")
  func defaultMissingKey() throws {
    let json = "{}"
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.popupSize == .comfortable)
  }

  @Test("AppSettings.popupSize round-trips through full JSON")
  func roundTripThroughAppSettings() throws {
    var settings = AppSettings()
    settings.popupSize = .spacious

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.popupSize == .spacious)
  }
}

// MARK: - UserEQPreset Model

@Suite("Compat: UserEQPreset — Model")
struct UpstreamUserEQPresetModelTests {
  @Test("Codable round-trip preserves all fields")
  func codableRoundTrip() throws {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_000_000)
    let settings = EQSettings(bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], isEnabled: false)
    let preset = UserEQPreset(id: id, name: "Test Preset", settings: settings, createdAt: date)

    let data = try JSONEncoder().encode(preset)
    let decoded = try JSONDecoder().decode(UserEQPreset.self, from: data)

    #expect(decoded.id == id)
    #expect(decoded.name == "Test Preset")
    #expect(decoded.settings.bandGains == settings.bandGains)
    #expect(decoded.createdAt == date)
  }

  @Test("Equatable compares all fields")
  func equatable() {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 500_000)
    let settings = EQSettings(bandGains: [3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    let a = UserEQPreset(id: id, name: "A", settings: settings, createdAt: date)
    let b = UserEQPreset(id: id, name: "A", settings: settings, createdAt: date)
    #expect(a == b)
  }

  @Test("Different IDs make presets non-equal")
  func differentIDsNotEqual() {
    let settings = EQSettings()
    let date = Date()
    let a = UserEQPreset(id: UUID(), name: "Same", settings: settings, createdAt: date)
    let b = UserEQPreset(id: UUID(), name: "Same", settings: settings, createdAt: date)
    #expect(a != b)
  }

  @Test("Default init generates unique IDs")
  func defaultInitUniqueIDs() {
    let a = UserEQPreset(name: "A", settings: EQSettings())
    let b = UserEQPreset(name: "B", settings: EQSettings())
    #expect(a.id != b.id)
  }

  @Test("isEnabled in EQSettings is carried but semantically ignored for presets")
  func isEnabledCarriedInSettings() throws {
    let withEnabled = UserEQPreset(
      name: "Enabled",
      settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: true)
    )
    let withDisabled = UserEQPreset(
      name: "Disabled",
      settings: EQSettings(bandGains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isEnabled: false)
    )

    let dataE = try JSONEncoder().encode(withEnabled)
    let dataD = try JSONEncoder().encode(withDisabled)
    let decodedE = try JSONDecoder().decode(UserEQPreset.self, from: dataE)
    let decodedD = try JSONDecoder().decode(UserEQPreset.self, from: dataD)

    #expect(decodedE.settings.isEnabled == true)
    #expect(decodedD.settings.isEnabled == false)
    #expect(decodedE.settings.bandGains == decodedD.settings.bandGains)
  }
}

// MARK: - VolumeControlTier Codable

@Suite("Compat: VolumeControlTier — Codable round-trip")
struct UpstreamVolumeControlTierCodableTests {
  @Test("All cases round-trip through JSON as their raw String value")
  func roundTripAllCases() throws {
    for tier in [VolumeControlTier.hardware, .ddc, .software] {
      let data = try JSONEncoder().encode(tier)
      let decoded = try JSONDecoder().decode(VolumeControlTier.self, from: data)
      #expect(decoded == tier)
    }
  }

  @Test("Encoded JSON matches the raw string form")
  func rawStringEncoding() throws {
    let encoded = try JSONEncoder().encode(VolumeControlTier.software)
    let s = String(data: encoded, encoding: .utf8)
    #expect(s == "\"software\"")
  }

  @Test("Dictionary keyed by String round-trips with VolumeControlTier values")
  func dictionaryRoundTrip() throws {
    let original: [String: VolumeControlTier] = [
      "uid-a": .hardware,
      "uid-b": .ddc,
      "uid-c": .software,
    ]
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode([String: VolumeControlTier].self, from: data)
    #expect(decoded == original)
  }
}

// MARK: - VolumeHotkeyStep Coverage

@Suite("Compat: Volume hotkey step counts cover the full range")
struct UpstreamVolumeHotkeyStepCoverageTests {
  @Test("Each step's N presses cover [0, 1] exactly", arguments: VolumeHotkeyStep.allCases)
  func stepCoverage(step: VolumeHotkeyStep) {
    let pressesToMax = Int(round(1.0 / step.sliderDelta))
    var slider: Double = 0
    for _ in 0..<pressesToMax {
      slider = min(1.0, slider + step.sliderDelta)
    }
    #expect(abs(slider - 1.0) < 1e-9)
  }

  @Test("Normal step covers range in exactly 16 presses (Apple-native count preserved)")
  func normalIs16Presses() {
    let pressesToMax = Int(round(1.0 / VolumeHotkeyStep.normal.sliderDelta))
    #expect(pressesToMax == 16)
  }
}

// MARK: - LoudnessEqualizerSettings Defaults

@Suite("Compat: LoudnessEqualizerSettings — MVP defaults")
struct UpstreamLoudnessEqualizerSettingsDefaultsTests {
  @Test("Settings default to approved MVP values")
  func settingsDefaults() {
    let s = LoudnessEqualizerSettings()
    #expect(s.targetLoudnessDb == -12)
    #expect(s.maxBoostDb == 6)
    #expect(s.maxCutDb == 4)
    #expect(s.compressionThresholdOffsetDb == 6)
    #expect(s.compressionRatio == 1.6)
    #expect(s.compressionKneeDb == 8)
    #expect(s.analysisWindowMs == 400)
    #expect(s.analysisHopMs == 100)
    #expect(s.detectorAttackMs == 25)
    #expect(s.detectorReleaseMs == 600)
    #expect(s.gainAttackMs == 250)
    #expect(s.gainReleaseMs == 3000)
    #expect(s.noiseFloorThresholdDb == -40)
    #expect(s.lowLevelMaxBoostDb == 0.5)
    #expect(s.enabled == false)
  }
}

// MARK: - AppSettings & VolumeMapping & EQSettings Compatibility Vectors

@Suite("Compat: AppSettings — Default values and unified loudness")
struct UpstreamAppSettingsDefaultTests {
  @Test("Default AppSettings has expected values")
  func defaults() {
    let settings = AppSettings()
    #expect(settings.launchAtLogin == false)
    #expect(settings.menuBarIconStyle == .default)
    #expect(settings.defaultNewAppVolume == 1.0)
    #expect(settings.lockInputDevice == true)
    #expect(settings.showDeviceDisconnectAlerts == true)
  }

  @Test("loudnessEqualizationEnabled defaults to false")
  func loudnessEqualizationEnabledDefault() {
    let settings = AppSettings()
    #expect(settings.loudnessEqualizationEnabled == false)
  }

  @Test("loudnessEqualizationEnabled round-trips through JSON as true")
  func loudnessEqualizationEnabledRoundTrip() throws {
    var settings = AppSettings()
    settings.loudnessEqualizationEnabled = true
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.loudnessEqualizationEnabled == true)
  }

  @Test("Unified loudness toggle updates compensation and equalization together")
  func unifiedLoudnessToggleSetsBothFlags() {
    var settings = AppSettings()

    settings.setUnifiedLoudnessEnabled(true)
    #expect(settings.loudnessCompensationEnabled == true)
    #expect(settings.loudnessEqualizationEnabled == true)

    settings.setUnifiedLoudnessEnabled(false)
    #expect(settings.loudnessCompensationEnabled == false)
    #expect(settings.loudnessEqualizationEnabled == false)
  }

  @Test("volumeHotkeyStep defaults to .normal")
  func volumeHotkeyStepDefault() {
    let settings = AppSettings()
    #expect(settings.volumeHotkeyStep == .normal)
  }

  @Test("volumeHotkeyStep round-trips through JSON")
  func volumeHotkeyStepRoundTrip() throws {
    var settings = AppSettings()
    settings.volumeHotkeyStep = .fine
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.volumeHotkeyStep == .fine)
  }

  @Test("Missing volumeHotkeyStep key decodes to .normal")
  func volumeHotkeyStepMissingKeyDefault() throws {
    let json = "{}".data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
    #expect(decoded.volumeHotkeyStep == .normal)
  }
}

@Suite("Compat: VolumeMapping — tier-aware system helpers")
struct UpstreamVolumeMappingTierTests {
  @Test("Software tier: gain 0.25 <-> sliderFraction 0.5")
  func softwareRoundTrip() {
    #expect(abs(VolumeMapping.sliderFraction(forSystemGain: 0.25, tier: .software) - 0.5) < 1e-6)
    #expect(abs(VolumeMapping.systemGain(forSliderFraction: 0.5, tier: .software) - 0.25) < 1e-6)
  }

  @Test("Hardware tier: identity in both directions")
  func hardwareIdentity() {
    #expect(abs(VolumeMapping.sliderFraction(forSystemGain: 0.3, tier: .hardware) - 0.3) < 1e-6)
    #expect(abs(VolumeMapping.systemGain(forSliderFraction: 0.3, tier: .hardware) - 0.3) < 1e-6)
  }

  @Test("DDC tier: identity in both directions")
  func ddcIdentity() {
    #expect(abs(VolumeMapping.sliderFraction(forSystemGain: 0.7, tier: .ddc) - 0.7) < 1e-6)
    #expect(abs(VolumeMapping.systemGain(forSliderFraction: 0.7, tier: .ddc) - 0.7) < 1e-6)
  }

  @Test("All tiers clamp out-of-range input")
  func clampsOutOfRange() {
    #expect(VolumeMapping.sliderFraction(forSystemGain: -0.1, tier: .software) == 0)
    #expect(VolumeMapping.sliderFraction(forSystemGain: 1.5, tier: .hardware) == 1.0)
    #expect(VolumeMapping.systemGain(forSliderFraction: -0.1, tier: .ddc) == 0)
    #expect(VolumeMapping.systemGain(forSliderFraction: 1.5, tier: .software) == 1.0)
  }
}

@Suite("Compat: EQSettings — Frequency constants and JSON compatibility")
struct UpstreamEQSettingsCompatibilityTests {
  @Test("Frequencies match ISO 10-band standard (31.25 Hz to 16 kHz)")
  func frequenciesMatchISO() {
    let expected: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    #expect(EQSettings.frequencies == expected)
  }

  @Test("Decoding with missing bandGains defaults to zeros")
  func missingBandGains() throws {
    let json = #"{"isEnabled": true}"#
    let decoded = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
    #expect(decoded.bandGains.count == EQSettings.bandCount)
    #expect(decoded.bandGains.allSatisfy { $0 == 0 })
  }

  @Test("Decoding with missing isEnabled defaults to true")
  func missingIsEnabled() throws {
    let json = #"{"bandGains": [0,0,0,0,0,0,0,0,0,0]}"#
    let decoded = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
    #expect(decoded.isEnabled)
  }

  @Test("Decoding with short bandGains array pads with zeros")
  func shortBandGainsPads() throws {
    let json = #"{"bandGains": [5.0, 3.0]}"#
    let decoded = try JSONDecoder().decode(EQSettings.self, from: Data(json.utf8))
    #expect(decoded.bandGains.count == EQSettings.bandCount)
    #expect(decoded.bandGains[0] == 5.0)
    #expect(decoded.bandGains[1] == 3.0)
    #expect(decoded.bandGains[2] == 0)
  }
}
