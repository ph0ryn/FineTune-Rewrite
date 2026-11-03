import Foundation

public enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case `default` = "Default"
  case speaker = "Speaker"
  case device = "Device"
  case waveform = "Waveform"
  case equalizer = "Equalizer"

  public var id: String { rawValue }
}

public enum HUDStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case tahoe, classic

  public var id: String { rawValue }
}

public enum AppearancePreference:
  String, Codable, CaseIterable, Identifiable, CustomStringConvertible, Sendable
{
  case system, light, dark

  public var id: String { rawValue }

  public var description: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

public enum MenuBarPopupSize:
  String, Codable, CaseIterable, Identifiable, CustomStringConvertible, Sendable
{
  case compact, comfortable, spacious

  public var id: String { rawValue }

  public var description: String {
    switch self {
    case .compact: "Compact"
    case .comfortable: "Comfortable"
    case .spacious: "Spacious"
    }
  }
}

public enum VolumeHotkeyStep:
  String, Codable, CaseIterable, Identifiable, CustomStringConvertible, Sendable
{
  case coarse, normal, fine, extraFine

  public var id: String { rawValue }

  /// A step in slider space, not a linear PCM gain delta.
  public var sliderDelta: Double {
    switch self {
    case .coarse: 1.0 / 8
    case .normal: 1.0 / 16
    case .fine: 1.0 / 32
    case .extraFine: 1.0 / 64
    }
  }

  public var description: String {
    switch self {
    case .coarse: "Coarse (12.5%)"
    case .normal: "Normal (6.25%)"
    case .fine: "Fine (3.13%)"
    case .extraFine: "Extra-Fine (1.56%)"
    }
  }
}

/// Stable saved key values; platform libraries provide conversion extensions.
public struct ShortcutCodable: Codable, Equatable, Hashable, Sendable {
  public var keyCode: Int
  public var modifiers: UInt

  public init(keyCode: Int, modifiers: UInt) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
}

/// User preferences only; loading files, operating the OS and mapping UI values live elsewhere.
public struct AppSettings: Codable, Equatable, Sendable {
  public var launchAtLogin = false
  public var menuBarIconStyle: MenuBarIconStyle = .default
  public var defaultNewAppVolume: Float = 1
  public var lockInputDevice = true
  public var showDeviceDisconnectAlerts = true
  public var loudnessCompensationEnabled = false
  public var loudnessEqualizationEnabled = false
  public var hudStyle: HUDStyle = .tahoe
  public var mediaKeyControlEnabled = true
  public var volumeHotkeyStep: VolumeHotkeyStep = .normal
  public var customShortcuts: [String: ShortcutCodable] = [:]
  public var appearance: AppearancePreference = .system
  public var popupSize: MenuBarPopupSize = .comfortable

  public init() {}

  public mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
    loudnessCompensationEnabled = enabled
    loudnessEqualizationEnabled = enabled
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    menuBarIconStyle =
      try values.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
    defaultNewAppVolume = try values.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1
    lockInputDevice = try values.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
    showDeviceDisconnectAlerts =
      try values.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
    loudnessCompensationEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
    loudnessEqualizationEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
    hudStyle = try values.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .tahoe
    mediaKeyControlEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .mediaKeyControlEnabled) ?? true
    volumeHotkeyStep =
      try values.decodeIfPresent(VolumeHotkeyStep.self, forKey: .volumeHotkeyStep) ?? .normal
    customShortcuts =
      try values.decodeIfPresent([String: ShortcutCodable].self, forKey: .customShortcuts) ?? [:]
    appearance =
      try values.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    popupSize =
      try values.decodeIfPresent(MenuBarPopupSize.self, forKey: .popupSize) ?? .comfortable
  }
}
