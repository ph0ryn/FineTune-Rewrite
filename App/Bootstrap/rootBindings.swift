import FineTuneControl
import FineTuneDomain
import FineTunePlatform

/// UI callbacks over the Root's actual Control owner; no wishes or effects queue live here.
@MainActor
struct RootBindings {
  let controller: AudioController
  let settings: SettingsManager

  var appActions: MixerAppActions {
    MixerAppActions(
      setVolume: { editGain(identifier: $0, gain: $1) },
      setMute: { controller.perform(.setMuted(identifier: $0, muted: $1)) },
      setBoost: { controller.perform(.setBoost(identifier: $0, boost: $1)) },
      followDefault: { controller.perform(.followDefault(identifier: $0)) },
      setRoute: { controller.perform(.setRoute(identifier: $0, mode: $1, uids: $2)) },
      setPinned: { controller.perform(.setPinned(identifier: $0, pinned: $1)) },
      setIgnored: { controller.perform(.setIgnored(identifier: $0, ignored: $1)) },
      setEQ: { controller.perform(.setEQ(identifier: $0, settings: $1)) },
      stepVolume: { controller.perform(.stepVolume(identifier: $0, isUp: $1, shift: $2)) },
      // Saved preset metadata does not alter already copied active EQ or native execution.
      createPreset: { settings.createUserPreset(name: $0, settings: $1) },
      renamePreset: { settings.updateUserPreset(id: $0, name: $1) },
      deletePreset: { settings.deleteUserPreset(id: $0) })
  }

  func resetAllSettings() {
    controller.perform(.resetAllSettings)
  }

  func updateSettings(_ settings: AppSettings) {
    controller.perform(.updateAppSettings(settings))
  }

  func editGain(identifier: String, gain: Float) {
    controller.perform(.editGain(identifier: identifier, gain: gain))
  }
}
