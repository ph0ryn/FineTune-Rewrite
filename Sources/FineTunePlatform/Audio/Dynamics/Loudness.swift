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

public enum LoudnessEqualizerMath {
  public static func dbToLinear(_ db: Float) -> Float { ft_loudness_db_to_linear(db) }
  public static func linearToDb(_ linear: Float) -> Float { ft_loudness_linear_to_db(linear) }
  public static func timeConstantCoefficient(timeMs: Float, stepMs: Float) -> Float {
    ft_loudness_time_coefficient(timeMs, stepMs)
  }
}

public final class KWeightingFilter {
  private let handle: OpaquePointer
  public init(sampleRate: Float) {
    guard let handle = ft_k_weighting_create(sampleRate) else {
      preconditionFailure("Unable to prepare K-weighting filter")
    }
    self.handle = handle
  }
  deinit { ft_k_weighting_destroy(handle) }
  public func reset() { ft_k_weighting_reset(handle) }
  public func processSample(_ sample: Float) -> Float {
    ft_k_weighting_process_sample(handle, sample)
  }
}

public final class LoudnessDetector {
  private let handle: OpaquePointer
  public init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
    var value = settings.nativeValue
    guard let handle = ft_loudness_detector_create(&value, sampleRate) else {
      preconditionFailure("Unable to prepare loudness detector")
    }
    self.handle = handle
  }
  deinit { ft_loudness_detector_destroy(handle) }
  public func ingest(weightedSample: Float) -> Float? {
    var level: Float = 0
    return ft_loudness_detector_ingest(handle, weightedSample, &level) ? level : nil
  }
  public func reset() { ft_loudness_detector_reset(handle) }
  public func updateEnvelope(with levelDb: Float) -> Float {
    ft_loudness_detector_update_envelope(handle, levelDb)
  }
}

public final class GainComputer {
  private var settings: FTLoudnessSettings
  public init(settings: LoudnessEqualizerSettings) { self.settings = settings.nativeValue }
  public func desiredGainDb(forLevelDb level: Float) -> Float {
    ft_loudness_desired_gain(&settings, level)
  }
}

public final class GainSmoother {
  private let handle: OpaquePointer
  public init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
    var value = settings.nativeValue
    guard let handle = ft_gain_smoother_create(&value, sampleRate) else {
      preconditionFailure("Unable to prepare gain smoother")
    }
    self.handle = handle
  }
  deinit { ft_gain_smoother_destroy(handle) }
  public func reset(initialGainDb: Float = 0) { ft_gain_smoother_reset(handle, initialGainDb) }
  public func process(targetGainDb: Float) -> Float {
    ft_gain_smoother_process(handle, targetGainDb)
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
