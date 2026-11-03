import FineTuneDomain

/// Fully prepared processing values passed to a runtime before it can start producing audio.
public struct TapInitialState: Equatable, Sendable {
  public var eqSettings: EQSettings
  public var autoEQProfile: AutoEQProfile?
  public var autoEQPreampEnabled: Bool
  public var loudnessVolume: Float
  public var loudnessCompensationEnabled: Bool
  public var loudnessEqualizerSettings: LoudnessEqualizerSettings

  public init(
    eqSettings: EQSettings = .flat, autoEQProfile: AutoEQProfile? = nil,
    autoEQPreampEnabled: Bool = false, loudnessVolume: Float = 1,
    loudnessCompensationEnabled: Bool = false,
    loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
  ) {
    self.eqSettings = eqSettings
    self.autoEQProfile = autoEQProfile
    self.autoEQPreampEnabled = autoEQPreampEnabled
    self.loudnessVolume = loudnessVolume
    self.loudnessCompensationEnabled = loudnessCompensationEnabled
    self.loudnessEqualizerSettings = loudnessEqualizerSettings
  }
}

/// Non-real-time route control. No raw OS objects or callback state cross this port.
@MainActor
public protocol AudioRouteControlling: AnyObject {
  var volume: Float { get set }
  var isMuted: Bool { get set }
  var currentDeviceVolume: Float { get set }
  var isDeviceMuted: Bool { get set }
  var audioLevel: Float { get }
  func activate(initial: TapInitialState) throws
  func invalidate()
  func updateEQSettings(_ settings: EQSettings)
  func updateAutoEQProfile(_ profile: AutoEQProfile?)
  func setAutoEQPreampEnabled(_ enabled: Bool)
  func updateLoudnessCompensation(volume: Float, enabled: Bool)
  func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
}

extension AudioRouteControlling {
  public func activate() throws { try activate(initial: TapInitialState()) }
}
