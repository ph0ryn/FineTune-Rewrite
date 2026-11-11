import FineTuneDomain
import Foundation

/// Metadata retained when an app is not running. Identity is independent of its current PID.
public struct SavedAppInfo: Codable, Equatable, Sendable {
  public let persistenceIdentifier: String
  public let displayName: String
  public let bundleID: String?

  public init(persistenceIdentifier: String, displayName: String, bundleID: String?) {
    self.persistenceIdentifier = persistenceIdentifier
    self.displayName = displayName
    self.bundleID = bundleID
  }
}

public typealias PinnedAppInfo = SavedAppInfo
public typealias IgnoredAppInfo = SavedAppInfo

/// The legacy JSON field names and units are a storage contract, not the runtime audio graph.
/// New documents use version 12; an absent legacy version is interpreted as version 9.
public struct SavedSettings: Codable, Equatable, Sendable {
  public var version = 12
  public var appSettings = AppSettings()
  public var appVolumes: [String: Float] = [:]
  public var appMutes: [String: Bool] = [:]
  public var appBoosts: [String: Float] = [:]
  public var appDeviceRouting: [String: String] = [:]
  public var appEQSettings: [String: EQSettings] = [:]
  public var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]
  public var appSelectedDeviceUIDs: [String: [String]] = [:]
  public var systemSoundsFollowsDefault = true
  public var lockedInputDeviceUID: String?
  public var preferredInputDeviceUID: String?
  public var pinnedApps: Set<String> = []
  public var pinnedAppInfo: [String: PinnedAppInfo] = [:]
  public var ignoredApps: Set<String> = []
  public var ignoredAppInfo: [String: IgnoredAppInfo] = [:]
  public var ddcVolumes: [String: Int] = [:]
  public var ddcMuteStates: [String: Bool] = [:]
  public var ddcSavedVolumes: [String: Int] = [:]
  public var softwareDeviceVolumes: [String: Float] = [:]
  public var softwareDeviceMuteStates: [String: Bool] = [:]
  public var softwareDeviceSavedVolumes: [String: Float] = [:]
  /// The OS alert volume owned by a mute-triggered silencing. A launch restores it before
  /// evaluating a new mute, so an interrupted or racing restore can finish on the next run.
  public var alertVolumeBeforeMuteSilencing: Float?
  public var deviceVolumeTierOverride: [String: VolumeControlTier] = [:]
  public var deviceIconOverrides: [String: String] = [:]
  public var outputDevicePriority: [String] = []
  public var inputDevicePriority: [String] = []
  public var hiddenOutputDeviceUIDs: Set<String> = []
  public var hiddenInputDeviceUIDs: Set<String> = []
  public var deviceAutoEQ: [String: AutoEQSelection] = [:]
  public var favoriteAutoEQProfiles: Set<String> = []
  public var autoEQPreampEnabled = true
  public var userEQPresets: [UserEQPreset] = []

  public init() {}

  public init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    func read<T: Decodable>(_ key: CodingKeys, default fallback: T) throws -> T {
      try values.decodeIfPresent(T.self, forKey: key) ?? fallback
    }
    version = try read(.version, default: 9)
    appSettings = try read(.appSettings, default: AppSettings())
    if !appSettings.defaultNewAppVolume.isFinite || appSettings.defaultNewAppVolume < 0 {
      appSettings.defaultNewAppVolume = 1
    }
    appVolumes = Self.decodedGains(try read(.appVolumes, default: [:]))
    appMutes = try read(.appMutes, default: [:])
    appBoosts = try read(.appBoosts, default: [:])
    appDeviceRouting = try read(.appDeviceRouting, default: [:])
    appEQSettings = try read(.appEQSettings, default: [:])
    appDeviceSelectionMode = try read(.appDeviceSelectionMode, default: [:])
    appSelectedDeviceUIDs = try read(.appSelectedDeviceUIDs, default: [:])
    systemSoundsFollowsDefault = try read(.systemSoundsFollowsDefault, default: true)
    lockedInputDeviceUID = try values.decodeIfPresent(String.self, forKey: .lockedInputDeviceUID)
    preferredInputDeviceUID = try values.decodeIfPresent(
      String.self, forKey: .preferredInputDeviceUID)
    pinnedApps = try read(.pinnedApps, default: [])
    pinnedAppInfo = try read(.pinnedAppInfo, default: [:])
    ignoredApps = try read(.ignoredApps, default: [])
    ignoredAppInfo = try read(.ignoredAppInfo, default: [:])
    ddcVolumes = try read(.ddcVolumes, default: [:])
    ddcMuteStates = try read(.ddcMuteStates, default: [:])
    ddcSavedVolumes = try read(.ddcSavedVolumes, default: [:])
    softwareDeviceVolumes = Self.decodedGains(try read(.softwareDeviceVolumes, default: [:]))
    softwareDeviceMuteStates = try read(.softwareDeviceMuteStates, default: [:])
    softwareDeviceSavedVolumes = Self.decodedGains(
      try read(.softwareDeviceSavedVolumes, default: [:]))
    alertVolumeBeforeMuteSilencing = try values.decodeIfPresent(
      Float.self, forKey: .alertVolumeBeforeMuteSilencing)
    deviceVolumeTierOverride = try read(.deviceVolumeTierOverride, default: [:])
    deviceIconOverrides = try read(.deviceIconOverrides, default: [:])
    outputDevicePriority = try read(.outputDevicePriority, default: [])
    inputDevicePriority = try read(.inputDevicePriority, default: [])
    hiddenOutputDeviceUIDs = try read(.hiddenOutputDeviceUIDs, default: [])
    hiddenInputDeviceUIDs = try read(.hiddenInputDeviceUIDs, default: [])
    deviceAutoEQ = try read(.deviceAutoEQ, default: [:])
    favoriteAutoEQProfiles = try read(.favoriteAutoEQProfiles, default: [])
    autoEQPreampEnabled = try read(.autoEQPreampEnabled, default: true)
    userEQPresets = try read(.userEQPresets, default: [])
  }

  private static func decodedGains(_ values: [String: Float]) -> [String: Float] {
    values.filter { $0.value.isFinite && $0.value >= 0 }.mapValues { min(1, $0) }
  }
}
