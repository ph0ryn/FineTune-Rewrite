import FineTuneControl
import FineTuneDomain
import Foundation
import SwiftUI

struct SettingsSnapshot {
  var settings: AppSettings
  var isAccessibilityTrusted: Bool
  var isMediaKeyOffline: Bool
  var error: String?
  var device: DeviceSettingsPresentation
}

/// Bundle metadata only; missing release information is never replaced with a shipped version.
struct SettingsAboutPresentation {
  var version: String?
  var build: String?
  var year: Int

  static var current: Self {
    Self(
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      year: Calendar.current.component(.year, from: .now))
  }

  var versionDescription: String {
    "Version \(version ?? "unavailable") (\(build ?? "build unavailable"))"
  }

  var copyright: String {
    let years = year == 2026 ? "2026" : "2026–\(year)"
    return "© \(years) Ronit Singh"
  }
}

enum SettingsSystemSoundChoice: Hashable {
  case followDefault
  case device(String)
  case unavailable
}

@MainActor
struct SettingsActions {
  let updateSettings: (AppSettings) -> Void
  let recordShortcut: (ShortcutAction, ShortcutCodable?) -> Void
  let requestAccessibility: () -> Void
  let retryMediaKeys: () -> Void
  let resetAll: () -> Void
  let device: DeviceSettingsActions
}

@MainActor
struct SettingsBindings {
  let read: () -> SettingsSnapshot
  let actions: SettingsActions

  /// A binding never captures an old AppSettings value to overwrite unrelated fields later.
  func field<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(
      get: { read().settings[keyPath: keyPath] },
      set: { value in
        var settings = read().settings
        settings[keyPath: keyPath] = value
        actions.updateSettings(settings)
      }
    )
  }

  var unifiedLoudness: Binding<Bool> {
    Binding(
      get: {
        read().settings.loudnessCompensationEnabled && read().settings.loudnessEqualizationEnabled
      },
      set: { value in
        var settings = read().settings
        settings.setUnifiedLoudnessEnabled(value)
        actions.updateSettings(settings)
      }
    )
  }

  var systemSounds: Binding<SettingsSystemSoundChoice> {
    Binding(
      get: {
        let current = read().device
        if current.followsDefault { return .followDefault }
        return current.systemOutputUID.map(SettingsSystemSoundChoice.device) ?? .unavailable
      },
      set: { value in
        switch value {
        case .followDefault: actions.device.setSystemFollowDefault()
        case .device(let uid): actions.device.setSystemOutput(uid)
        case .unavailable: preconditionFailure("An unavailable output is not a selectable choice")
        }
      })
  }

  var alertVolume: Binding<Double>? {
    guard let displayed = read().device.alertVolume, read().device.canSetAlertVolume else {
      return nil
    }
    return Binding(
      get: { Double(read().device.alertVolume ?? displayed) },
      set: { actions.device.setAlertVolume(Float($0)) })
  }

  /// The original preference editor is a direct scalar, unlike the per-app perceptual slider.
  var defaultVolume: Binding<Double> {
    Binding(
      get: { Double(read().settings.defaultNewAppVolume) },
      set: { value in
        var settings = read().settings
        settings.defaultNewAppVolume = Float(value)
        actions.updateSettings(settings)
      }
    )
  }
}
