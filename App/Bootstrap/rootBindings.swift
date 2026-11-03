import FineTuneControl
import FineTuneDomain

/// UI callbacks over the Root's actual Control owner; no wishes or effects queue live here.
@MainActor
struct RootBindings {
  let controller: AudioController

  func updateSettings(_ settings: AppSettings) {
    controller.perform(.updateAppSettings(settings))
  }

  func editGain(identifier: String, gain: Float) {
    controller.perform(.editGain(identifier: identifier, gain: gain))
  }
}
