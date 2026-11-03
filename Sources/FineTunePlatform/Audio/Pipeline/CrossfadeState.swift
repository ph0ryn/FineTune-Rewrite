import NativeAudio

public enum CrossfadePhase: UInt32 {
  case idle = 0
  case warmingUp = 1
  case crossfading = 2
}

/// Pure transition value for a single serialized owner. It is intentionally not Sendable;
/// copying a snapshot does not provide cross-callback publication or lifetime management.
public struct CrossfadeState {
  private var native = ft_crossfade_initial_state()

  public init() {}

  public var progress: Float {
    get { native.progress }
    set { native.progress = newValue }
  }
  public var phase: CrossfadePhase {
    get { CrossfadePhase(rawValue: native.phase)! }
    set { native.phase = newValue.rawValue }
  }
  public var secondarySampleCount: Int64 {
    get { native.secondary_sample_count }
    set { native.secondary_sample_count = newValue }
  }
  public var totalSamples: Int64 {
    get { native.total_samples }
    set { native.total_samples = newValue }
  }
  public var secondarySamplesProcessed: Int {
    get { Int(native.secondary_samples_processed) }
    set { native.secondary_samples_processed = Int64(newValue) }
  }
  public static var minimumWarmupSamples: Int { Int(ft_crossfade_minimum_warmup_samples()) }
  public var isActive: Bool { phase != .idle }
  public var isWarmupComplete: Bool {
    native.secondary_samples_processed >= ft_crossfade_minimum_warmup_samples()
  }
  public var isCrossfadeComplete: Bool { progress >= 1 }
  public var primaryMultiplier: Float {
    var snapshot = native
    return ft_crossfade_primary_multiplier(&snapshot)
  }
  public var secondaryMultiplier: Float {
    var snapshot = native
    return ft_crossfade_secondary_multiplier(&snapshot)
  }

  public mutating func beginWarmup() {
    precondition(ft_crossfade_begin_warmup(&native) == FT_PIPELINE_OK)
  }
  public mutating func beginCrossfading() {
    precondition(ft_crossfade_begin_crossfading(&native) == FT_PIPELINE_OK)
  }
  public mutating func complete() {
    precondition(ft_crossfade_complete(&native) == FT_PIPELINE_OK)
  }
  @discardableResult
  public mutating func updateProgress(samples: Int) -> Float {
    precondition(ft_crossfade_advance(&native, Int64(samples)) == FT_PIPELINE_OK)
    return native.progress
  }
}
