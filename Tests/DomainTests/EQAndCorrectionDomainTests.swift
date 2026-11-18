import FineTuneDomain
import Foundation
import Testing

@Suite("Domain: EQ settings, presets, and AutoEQ profile invariants")
struct EQAndCorrectionDomainTests {
  @Test("EQSettings normalizes band counts by zero-padding short arrays and truncating long ones")
  func eqNormalization() {
    #expect(EQSettings.flat.bandGains == Array(repeating: 0, count: 10))
    #expect(EQSettings.flat.isEnabled)
    #expect(EQSettings.frequencies.count == EQSettings.bandCount)

    let short = EQSettings(bandGains: [3, -2], isEnabled: false)
    #expect(short.bandGains == [3, -2, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(!short.isEnabled)

    let long = EQSettings(bandGains: Array(1...15).map(Float.init))
    #expect(long.bandGains == Array(1...10).map(Float.init))
  }

  @Test("clampedGains clamps finite values to [-12, 12] and maps non-finite values to zero")
  func eqClampingAndNonFinite() {
    let input: [Float] = [-20, -12, -5.5, 0, 12, 25, .nan, .infinity, -.infinity, 1.5]
    let eq = EQSettings(bandGains: input)
    #expect(eq.clampedGains == [-12, -12, -5.5, 0, 12, 12, 0, 0, 0, 1.5])
  }

  @Test("EQSettings decoding tolerates missing fields with flat enabled defaults")
  func eqDecodingDefaults() throws {
    let decoded = try JSONDecoder().decode(EQSettings.self, from: Data("{}".utf8))
    #expect(decoded == .flat)
  }

  @Test("All EQPreset cases cover categories cleanly and produce valid 10-band settings")
  func presetCatalogIntegrity() {
    // Catalog size is a compatibility contract: 20 presets across all categories.
    #expect(EQPreset.allCases.count == 20)

    let grouped = EQPreset.Category.allCases.flatMap { EQPreset.presets(for: $0) }
    #expect(Set(grouped.map(\.id)) == Set(EQPreset.allCases.map(\.id)))
    #expect(grouped.count == EQPreset.allCases.count)

    for category in EQPreset.Category.allCases {
      let presets = EQPreset.presets(for: category)
      #expect(!presets.isEmpty, "Category \(category.rawValue) has no presets")
      for preset in presets {
        #expect(
          preset.category == category,
          "Preset \(preset.rawValue) returned under category \(category.rawValue)")
      }
    }

    for preset in EQPreset.allCases {
      #expect(!preset.name.isEmpty)
      let settings = preset.settings
      #expect(settings.bandGains.count == EQSettings.bandCount)
      #expect(settings.bandGains == settings.clampedGains)
      #expect(settings.isEnabled)
    }
  }

  @Test("AutoEQProfile.validated filters invalid bands, caps at 10 filters, and clamps preamp")
  func autoEQProfileValidation() {
    let validFilter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3, q: 1.4)
    let invalidFilters = [
      AutoEQFilter(type: .peaking, frequency: 0, gainDB: 3, q: 1),
      AutoEQFilter(type: .lowShelf, frequency: -100, gainDB: 3, q: 1),
      AutoEQFilter(type: .highShelf, frequency: 500, gainDB: 3, q: 0),
      AutoEQFilter(type: .peaking, frequency: 500, gainDB: 3, q: -0.5),
      AutoEQFilter(type: .peaking, frequency: 500, gainDB: 31, q: 1),
      AutoEQFilter(type: .peaking, frequency: 500, gainDB: -31, q: 1),
    ]
    let manyValid = Array(repeating: validFilter, count: 12)
    let profile = AutoEQProfile(
      id: "p1", name: "Test", source: .imported, preampDB: -45,
      filters: invalidFilters + manyValid, measuredBy: "oratory1990", optimizedSampleRate: 44100)

    let validated = profile.validated()
    #expect(validated.preampDB == -30)
    #expect(validated.filters.count == AutoEQProfile.maxFilters)
    #expect(validated.filters.allSatisfy { $0 == validFilter })
    #expect(validated.optimizedSampleRate == 44100)

    let highPreamp = AutoEQProfile(
      id: "p2", name: "High", source: .fetched, preampDB: 50, filters: [])
    #expect(highPreamp.validated().preampDB == 30)
  }

  @Test("AutoEQProfile decoding defaults optimizedSampleRate to 48000 when omitted")
  func autoEQProfileSampleRateDefault() throws {
    let json = """
      {"id":"p","name":"N","source":"fetched","preampDB":-2.5,"filters":[]}
      """
    let decoded = try JSONDecoder().decode(AutoEQProfile.self, from: Data(json.utf8))
    #expect(decoded.optimizedSampleRate == 48000)
    #expect(decoded.measuredBy == nil)
  }
}
