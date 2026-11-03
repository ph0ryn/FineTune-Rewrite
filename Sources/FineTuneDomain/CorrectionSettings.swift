/// One parametric filter, expressed as values rather than mutable DSP history.
public struct AutoEQFilter: Codable, Equatable, Sendable {
  public enum FilterType: String, Codable, Sendable {
    case peaking, lowShelf, highShelf
  }

  public let type: FilterType
  public let frequency: Double
  public let gainDB: Float
  public let q: Double

  public init(type: FilterType, frequency: Double, gainDB: Float, q: Double) {
    self.type = type
    self.frequency = frequency
    self.gainDB = gainDB
    self.q = q
  }
}

public enum AutoEQSource: String, Codable, Sendable {
  case bundled, imported, fetched
}

public struct AutoEQProfile: Codable, Equatable, Identifiable, Sendable {
  public static let maxFilters = 10

  public let id: String
  public let name: String
  public let source: AutoEQSource
  public let preampDB: Float
  public let filters: [AutoEQFilter]
  public let measuredBy: String?
  public var optimizedSampleRate: Double

  public init(
    id: String, name: String, source: AutoEQSource, preampDB: Float,
    filters: [AutoEQFilter], measuredBy: String? = nil, optimizedSampleRate: Double = 48000
  ) {
    self.id = id
    self.name = name
    self.source = source
    self.preampDB = preampDB
    self.filters = filters
    self.measuredBy = measuredBy
    self.optimizedSampleRate = optimizedSampleRate
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(String.self, forKey: .id),
      name: try values.decode(String.self, forKey: .name),
      source: try values.decode(AutoEQSource.self, forKey: .source),
      preampDB: try values.decode(Float.self, forKey: .preampDB),
      filters: try values.decode([AutoEQFilter].self, forKey: .filters),
      measuredBy: try values.decodeIfPresent(String.self, forKey: .measuredBy),
      optimizedSampleRate: try values.decodeIfPresent(Double.self, forKey: .optimizedSampleRate)
        ?? 48000
    )
  }

  public func validated() -> AutoEQProfile {
    let validFilters = filters.filter { $0.frequency > 0 && $0.q > 0 && abs($0.gainDB) <= 30 }
    return AutoEQProfile(
      id: id, name: name, source: source, preampDB: max(-30, min(30, preampDB)),
      filters: Array(validFilters.prefix(Self.maxFilters)), measuredBy: measuredBy,
      optimizedSampleRate: optimizedSampleRate
    )
  }
}

/// Device-keyed selections retain the requested profile independently of runtime availability.
public struct AutoEQSelection: Codable, Equatable, Sendable {
  public let profileID: String
  public var isEnabled: Bool

  public init(profileID: String, isEnabled: Bool) {
    self.profileID = profileID
    self.isEnabled = isEnabled
  }
}

/// Control parameters only; each processing route owns its own detector and gain history.
public struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
  public var targetLoudnessDb: Float = -12
  public var maxBoostDb: Float = 6
  public var maxCutDb: Float = 4
  public var compressionThresholdOffsetDb: Float = 6
  public var compressionRatio: Float = 1.6
  public var compressionKneeDb: Float = 8
  public var analysisWindowMs: Float = 400
  public var analysisHopMs: Float = 100
  public var detectorAttackMs: Float = 25
  public var detectorReleaseMs: Float = 600
  public var gainAttackMs: Float = 250
  public var gainReleaseMs: Float = 3000
  public var noiseFloorThresholdDb: Float = -40
  public var lowLevelMaxBoostDb: Float = 0.5
  public var enabled: Bool = false

  public init() {}
}
