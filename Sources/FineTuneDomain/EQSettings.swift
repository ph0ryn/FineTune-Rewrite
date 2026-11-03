import Foundation

/// Ten-band graphic EQ values in dB. The stored values and processing limits are distinct.
public struct EQSettings: Codable, Equatable, Sendable {
  public static let bandCount = 10
  public static let minGainDB: Float = -12
  public static let maxGainDB: Float = 12
  public static let frequencies: [Double] = [
    31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ]

  public var bandGains: [Float]
  public var isEnabled: Bool

  public init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
    self.bandGains = Self.normalized(bandGains)
    self.isEnabled = isEnabled
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      bandGains: try values.decodeIfPresent([Float].self, forKey: .bandGains) ?? [],
      isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    )
  }

  public var clampedGains: [Float] {
    bandGains.map { $0.isFinite ? max(Self.minGainDB, min(Self.maxGainDB, $0)) : 0 }
  }

  public static let flat = EQSettings()

  private static func normalized(_ gains: [Float]) -> [Float] {
    let bands = Array(gains.prefix(bandCount))
    return bands + Array(repeating: 0, count: bandCount - bands.count)
  }
}

/// The built-in preset catalog shared by settings, controls and processing configuration.
public enum EQPreset: String, CaseIterable, Identifiable, Sendable {
  case flat, bassBoost, bassCut, trebleBoost
  case vocalClarity, podcast, spokenWord
  case loudness, lateNight, smallSpeakers
  case rock, pop, electronic, jazz, classical, hipHop, rnb, deep, acoustic
  case movie

  public var id: String { rawValue }

  public enum Category: String, CaseIterable, Identifiable, Sendable {
    case utility = "Utility"
    case speech = "Speech"
    case listening = "Listening"
    case music = "Music"
    case media = "Media"

    public var id: String { rawValue }
  }

  public var category: Category {
    switch self {
    case .flat, .bassBoost, .bassCut, .trebleBoost: .utility
    case .vocalClarity, .podcast, .spokenWord: .speech
    case .loudness, .lateNight, .smallSpeakers: .listening
    case .rock, .pop, .electronic, .jazz, .classical, .hipHop, .rnb, .deep, .acoustic: .music
    case .movie: .media
    }
  }

  public static func presets(for category: Category) -> [EQPreset] {
    allCases.filter { $0.category == category }
  }

  public var name: String {
    switch self {
    case .flat: "Flat"
    case .bassBoost: "Bass Boost"
    case .bassCut: "Bass Cut"
    case .trebleBoost: "Treble Boost"
    case .vocalClarity: "Vocal Clarity"
    case .podcast: "Podcast"
    case .spokenWord: "Spoken Word"
    case .loudness: "Loudness"
    case .lateNight: "Late Night"
    case .smallSpeakers: "Small Speakers"
    case .rock: "Rock"
    case .pop: "Pop"
    case .electronic: "Electronic"
    case .jazz: "Jazz"
    case .classical: "Classical"
    case .hipHop: "Hip-Hop"
    case .rnb: "R&B"
    case .deep: "Deep"
    case .acoustic: "Acoustic"
    case .movie: "Movie"
    }
  }

  public var settings: EQSettings {
    let gains: [Float] =
      switch self {
      case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      case .bassBoost: [6, 6, 5, -1, 0, 0, 0, 0, 0, 0]
      case .bassCut: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]
      case .trebleBoost: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]
      case .vocalClarity: [-4, -2, -1, -3, 0, 2, 4, 4, 1, 0]
      case .podcast: [-6, -4, -2, -1, 0, 2, 4, 3, 1, 0]
      case .spokenWord: [-8, -6, -3, -2, 0, 2, 4, 4, 2, 0]
      case .loudness: [5, 4, 2, 0, -2, -2, 0, 2, 4, 5]
      case .lateNight: [-6, -4, -2, 0, 0, 1, 2, 2, 1, 0]
      case .smallSpeakers: [3, 4, 5, 2, 0, 1, 2, 2, 1, 0]
      case .rock: [4, 3, 2, 0, -1, 0, 2, 3, 2, 1]
      case .pop: [3, 3, 2, 0, -1, 1, 2, 3, 3, 4]
      case .electronic: [7, 6, 4, 0, -2, -2, 1, 3, 4, 3]
      case .jazz: [3, 2, 1, 0, 0, 0, 1, 2, 2, 1]
      case .classical: [0, 0, 0, 0, 0, 0, 1, 2, 2, 2]
      case .hipHop: [6, 5, 4, 0, -1, 0, 2, 3, 4, 3]
      case .rnb: [4, 4, 3, 1, -1, 0, 2, 3, 3, 2]
      case .deep: [5, 6, 4, 1, -2, -2, 0, 1, 2, 1]
      case .acoustic: [0, 1, 2, 2, 1, 0, 1, 2, 2, 1]
      case .movie: [4, 4, 3, -1, -1, 1, 3, 3, 2, 1]
      }
    return EQSettings(bandGains: gains)
  }
}

/// A saved curve; applying it must not replace the app's independent EQ enable state.
public struct UserEQPreset: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var settings: EQSettings
  public let createdAt: Date

  public init(id: UUID = UUID(), name: String, settings: EQSettings, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.settings = settings
    self.createdAt = createdAt
  }
}
