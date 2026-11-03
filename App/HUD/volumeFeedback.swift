import AppKit
import FineTuneDomain
import os

/// The feedback sound bypasses application taps, so software volume must be applied here.
enum VolumeFeedback {
  static func shouldPlay(prefOn: Bool, shiftHeld: Bool, optionHeld: Bool) -> Bool {
    shiftHeld && !optionHeld ? !prefOn : prefOn
  }

  static func gain(tier: VolumeControlTier, sliderFraction: Double) -> Float {
    tier == .software
      ? VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: .software)
      : 1
  }
}

@MainActor
final class VolumeFeedbackPlayer {
  static let cooldown: TimeInterval = 0.15
  private var lastPlay: TimeInterval = -.infinity
  private let playback = FeedbackPlayback()
  private let logger = Logger(subsystem: "FineTune.Rewrite", category: "VolumeFeedback")

  func passesCooldown(at time: TimeInterval) -> Bool {
    guard time - lastPlay >= Self.cooldown else { return false }
    lastPlay = time
    return true
  }

  static func systemPreferenceEnabled() -> Bool {
    CFPreferencesGetAppBooleanValue(
      "com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication, nil
    )
  }

  /// Only an explicit user volume action requests playback. Construction and gate tests are silent.
  func requestFeedback(gain: Float, shiftHeld: Bool = false, optionHeld: Bool = false) {
    guard
      VolumeFeedback.shouldPlay(
        prefOn: Self.systemPreferenceEnabled(), shiftHeld: shiftHeld, optionHeld: optionHeld
      ), passesCooldown(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    Task {
      do { try await playback.play(gain: gain) } catch {
        logger.error("Volume feedback failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

/// Serial, non-main-actor ownership keeps the blocking NSSound play call off UI interactions.
private actor FeedbackPlayback {
  private var sound: NSSound?

  enum PlaybackError: Error { case soundUnavailable, playbackRejected }

  func play(gain: Float) throws {
    if sound == nil {
      let paths = [
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        "/System/Library/Sounds/Tink.aiff",
      ]
      sound = paths.lazy.compactMap { NSSound(contentsOfFile: $0, byReference: true) }.first
    }
    guard let sound else { throw PlaybackError.soundUnavailable }
    sound.stop()
    sound.volume = gain
    guard sound.play() else { throw PlaybackError.playbackRejected }
  }
}
