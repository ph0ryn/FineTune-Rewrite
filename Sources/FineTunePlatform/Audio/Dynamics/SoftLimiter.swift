import NativeAudio

/// Stateless control/test adapter to the native production limiter.
public enum SoftLimiter {
  public static let threshold: Float = 0.95
  public static let ceiling: Float = 1
  public static let headroom: Float = ceiling - threshold

  public static func apply(_ sample: Float) -> Float { ft_soft_limiter_apply(sample) }

  public static func processBuffer(_ samples: UnsafeMutablePointer<Float>, sampleCount: Int) {
    precondition(sampleCount >= 0 && UInt32(exactly: sampleCount) != nil)
    ft_soft_limiter_process(samples, UInt32(sampleCount))
  }
}
