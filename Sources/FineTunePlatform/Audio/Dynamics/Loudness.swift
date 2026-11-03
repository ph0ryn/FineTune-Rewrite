import FineTuneDomain
import NativeAudio

extension LoudnessEqualizerSettings {
  var nativeValue: FTLoudnessSettings {
    FTLoudnessSettings(
      target_loudness_db: targetLoudnessDb, max_boost_db: maxBoostDb, max_cut_db: maxCutDb,
      compression_threshold_offset_db: compressionThresholdOffsetDb,
      compression_ratio: compressionRatio,
      compression_knee_db: compressionKneeDb, analysis_window_ms: analysisWindowMs,
      analysis_hop_ms: analysisHopMs, detector_attack_ms: detectorAttackMs,
      detector_release_ms: detectorReleaseMs, gain_attack_ms: gainAttackMs,
      gain_release_ms: gainReleaseMs, noise_floor_threshold_db: noiseFloorThresholdDb,
      low_level_max_boost_db: lowLevelMaxBoostDb, enabled: enabled)
  }
}

/// A non-Sendable control/test owner. Native execution routes clone configuration and
/// process directly in C++; the HAL callback never calls this Swift adapter.
public final class LoudnessEqualizer {
  private let handle: OpaquePointer
  public init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
    var value = settings.nativeValue
    guard let handle = ft_loudness_equalizer_create(&value, sampleRate) else {
      preconditionFailure("Unable to prepare loudness equalizer")
    }
    self.handle = handle
  }
  deinit { ft_loudness_equalizer_destroy(handle) }
  public func withNativeHandle<Result>(_ body: (OpaquePointer) -> Result) -> Result { body(handle) }
  @discardableResult
  public func process(
    input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int,
    channelCount: Int
  ) -> Int32 {
    guard let frames = UInt32(exactly: frameCount), let channels = UInt32(exactly: channelCount)
    else {
      return 1
    }
    return ft_loudness_equalizer_process(handle, input, output, frames, channels)
  }
}
