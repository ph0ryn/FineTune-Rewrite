import NativeAudio

/// Value adapter to the native ISO 226:2023 model. Approximation is separate from
/// the normative contour and is prepared only on the non-realtime control path.
public enum ISO226Contours {
  public static let referenceLoudnessExponent = 0.300
  public static let defaultReferencePhon = 80.0
  public static let frequencies = referenceData(column: 0)
  public static let loudnessPerceptionExponents = referenceData(column: 1)
  public static let transferMagnitudesDB = referenceData(column: 2)
  public static let hearingThresholdsDB = referenceData(column: 3)

  public static func estimatedPhon(fromSystemVolume volume: Float) -> Double {
    ft_iso226_estimated_phon(volume)
  }
  public static func contourSPL(atPhon phon: Double) -> [Double] {
    var output = [Double](repeating: 0, count: 29)
    output.withUnsafeMutableBufferPointer { ft_iso226_contour(phon, $0.baseAddress) }
    return output
  }
  public static func compensationGains(
    atPhon phon: Double, referencePhon: Double = defaultReferencePhon,
    amount: Double = 1, maxGainDB: Double = .greatestFiniteMagnitude
  ) -> [Double] {
    var output = [Double](repeating: 0, count: 29)
    output.withUnsafeMutableBufferPointer {
      ft_iso226_compensation(phon, referencePhon, amount, maxGainDB, $0.baseAddress)
    }
    return output
  }
  public static func requiredHeadroomDB(forCompensationGains gains: [Double]) -> Double {
    max(0, gains.max() ?? 0)
  }
  public static func interpolateCompensation(_ gains: [Double], atFrequency frequency: Double)
    -> Double
  {
    gains.withUnsafeBufferPointer {
      ft_iso226_interpolate($0.baseAddress, UInt32($0.count), frequency)
    }
  }
  private static func referenceData(column: UInt32) -> [Double] {
    var output = [Double](repeating: 0, count: 29)
    let result = output.withUnsafeMutableBufferPointer {
      ft_iso226_reference_data(column, $0.baseAddress)
    }
    precondition(result == 0)
    return output
  }
}

public final class LoudnessCompensator {
  public static let bandCount = 4
  private let handle: OpaquePointer
  public init(sampleRate: Double = 48000) {
    guard let handle = ft_loudness_compensator_create(sampleRate) else {
      preconditionFailure("Unable to prepare loudness compensator")
    }
    self.handle = handle
  }
  deinit { ft_loudness_compensator_destroy(handle) }
  public var isEnabled: Bool { ft_loudness_compensator_is_enabled(handle) }
  public func setEnabled(_ enabled: Bool) { ft_loudness_compensator_set_enabled(handle, enabled) }
  public func updateForVolume(_ volume: Float) {
    precondition(ft_loudness_compensator_update_volume(handle, volume) == 0)
  }
  public func withNativeHandle<Result>(_ body: (OpaquePointer) -> Result) -> Result { body(handle) }
  @discardableResult
  public func process(
    input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int
  ) -> Int32 {
    guard let frames = UInt32(exactly: frameCount) else { return 1 }
    return ft_loudness_compensator_process(handle, input, output, frames)
  }
  public static func fittedSectionGains(forPhon phon: Double, sampleRate: Double) -> [Double] {
    var output = [Double](repeating: 0, count: bandCount)
    output.withUnsafeMutableBufferPointer {
      ft_loudness_fitted_gains(phon, sampleRate, $0.baseAddress)
    }
    return output
  }
  public static func coefficientsForBands(gains: [Double], sampleRate: Double) -> [Double] {
    precondition(gains.count == bandCount)
    var output = [Double](repeating: 0, count: bandCount * 5)
    gains.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer {
        ft_loudness_band_coefficients(input.baseAddress, sampleRate, $0.baseAddress)
      }
    }
    return output
  }
}
