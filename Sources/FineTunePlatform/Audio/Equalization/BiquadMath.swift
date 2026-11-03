import FineTuneDomain
import NativeAudio

/// Non-realtime value adapter. All filter calculations are implemented by AudioDSP.
public enum BiquadMath {
  public static let graphicEQQ = 1.4

  public static func peakingEQCoefficients(
    frequency: Double, gainDB: Float, q: Double, sampleRate: Double
  ) -> [Double] {
    calculate(
      type: FT_BIQUAD_PEAKING, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
  }

  public static func lowShelfCoefficients(
    frequency: Double, gainDB: Float, q: Double, sampleRate: Double
  ) -> [Double] {
    calculate(
      type: FT_BIQUAD_LOW_SHELF, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
  }

  public static func highShelfCoefficients(
    frequency: Double, gainDB: Float, q: Double, sampleRate: Double
  ) -> [Double] {
    calculate(
      type: FT_BIQUAD_HIGH_SHELF, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate
    )
  }

  public static func preWarpFrequency(
    _ frequency: Double, from sourceRate: Double, to targetRate: Double
  ) -> Double {
    ft_biquad_prewarp(frequency, sourceRate, targetRate)
  }

  public static func coefficientsForAllBands(gains: [Float], sampleRate: Double) -> [Double] {
    var output = [Double](repeating: 0, count: EQSettings.bandCount * 5)
    let status = gains.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { result in
        ft_biquad_graphic_coefficients(
          input.baseAddress, UInt32(input.count), sampleRate, result.baseAddress)
      }
    }
    precondition(status == FT_BIQUAD_OK, "Invalid graphic EQ coefficient configuration")
    return output
  }

  public static func coefficientsForAutoEQFilters(
    _ filters: [AutoEQFilter], sampleRate: Double, profileOptimizedRate: Double = 48000
  ) -> [Double] {
    let specifications = filters.map { filter in
      let type: FTBiquadFilterType
      switch filter.type {
      case .peaking: type = FT_BIQUAD_PEAKING
      case .lowShelf: type = FT_BIQUAD_LOW_SHELF
      case .highShelf: type = FT_BIQUAD_HIGH_SHELF
      }
      return FTBiquadFilter(
        type: type, frequency: filter.frequency, gain_db: filter.gainDB, q: filter.q)
    }
    var output = [Double](repeating: 0, count: filters.count * 5)
    let status = specifications.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { result in
        ft_biquad_autoeq_coefficients(
          input.baseAddress, UInt32(input.count), sampleRate, profileOptimizedRate,
          result.baseAddress)
      }
    }
    precondition(status == FT_BIQUAD_OK, "Invalid AutoEQ coefficient configuration")
    return output
  }

  private static func calculate(
    type: FTBiquadFilterType, frequency: Double, gainDB: Float, q: Double, sampleRate: Double
  ) -> [Double] {
    var output = [Double](repeating: 0, count: 5)
    let filter = FTBiquadFilter(type: type, frequency: frequency, gain_db: gainDB, q: q)
    let status = output.withUnsafeMutableBufferPointer {
      ft_biquad_coefficients(filter, sampleRate, $0.baseAddress)
    }
    precondition(status == FT_BIQUAD_OK, "Invalid biquad coefficient parameters")
    return output
  }
}
