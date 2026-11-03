import Darwin
import FineTuneDomain
import NativeAudio

/// Control/test-facing adapter to the same native processor used by native audio routes.
/// This non-Sendable owner must be quiescent during configuration and destruction.
/// HAL processing calls the C/C++ API directly, never this Swift object.
open class BiquadProcessor {
  public private(set) var sampleRate: Double
  public let maxSections: Int
  public let category: String
  private let nativeHandle: OpaquePointer

  public init(
    sampleRate: Double, maxSections: Int, category: String, initiallyEnabled: Bool = false
  ) {
    precondition(sampleRate.isFinite && sampleRate > 0)
    precondition((1...10).contains(maxSections))
    guard let handle = ft_biquad_create(2) else {
      preconditionFailure("Unable to prepare native biquad processor")
    }
    self.sampleRate = sampleRate
    self.maxSections = maxSections
    self.category = category
    nativeHandle = handle
    ft_biquad_set_enabled(handle, initiallyEnabled)
  }

  deinit { ft_biquad_destroy(nativeHandle) }

  public var isEnabled: Bool { ft_biquad_is_enabled(nativeHandle) }

  public func setEnabled(_ enabled: Bool) { ft_biquad_set_enabled(nativeHandle, enabled) }

  /// Synchronous borrow for copying configuration into a distinct native execution route.
  /// The closure must not retain the pointer or destroy the borrowed processor.
  public func withNativeHandle<Result>(_ body: (OpaquePointer) -> Result) -> Result {
    body(nativeHandle)
  }

  /// Non-RT replacement copies coefficients and resets history. nil explicitly selects bypass.
  @discardableResult
  public func replaceCoefficients(_ coefficients: [Double]?, sectionCount: Int) -> FTBiquadStatus {
    guard sectionCount >= 0 && sectionCount <= maxSections,
      coefficients?.count == sectionCount * 5 || coefficients == nil && sectionCount == 0
    else { return FT_BIQUAD_INVALID_ARGUMENT }
    guard let coefficients else {
      return ft_biquad_replace_coefficients(nativeHandle, nil, 0)
    }
    return coefficients.withUnsafeBufferPointer {
      ft_biquad_replace_coefficients(nativeHandle, $0.baseAddress, UInt32(sectionCount))
    }
  }

  @discardableResult
  public func replaceCoefficients(_ coefficients: [Double]?) -> FTBiquadStatus {
    replaceCoefficients(coefficients, sectionCount: (coefficients?.count ?? 0) / 5)
  }

  public func resetDelayBuffers() { ft_biquad_reset(nativeHandle) }

  open func updateSampleRate(_ sampleRate: Double) {
    precondition(sampleRate.isFinite && sampleRate > 0)
    self.sampleRate = sampleRate
    resetDelayBuffers()
  }

  @discardableResult
  public func process(
    input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int
  ) -> FTBiquadStatus {
    guard let frames = UInt32(exactly: frameCount) else { return FT_BIQUAD_INVALID_ARGUMENT }
    return ft_biquad_process(nativeHandle, input, output, frames)
  }
}

public final class EQProcessor: BiquadProcessor {
  private var settings = EQSettings.flat

  public init(sampleRate: Double = 48000) {
    super.init(sampleRate: sampleRate, maxSections: EQSettings.bandCount, category: "graphic-eq")
  }

  public func updateSettings(_ settings: EQSettings) {
    let coefficients = BiquadMath.coefficientsForAllBands(
      gains: settings.clampedGains, sampleRate: sampleRate)
    let result = replaceCoefficients(coefficients, sectionCount: EQSettings.bandCount)
    precondition(result == FT_BIQUAD_OK, "Unable to prepare graphic EQ")
    self.settings = settings
    setEnabled(settings.isEnabled)
  }

  public override func updateSampleRate(_ sampleRate: Double) {
    super.updateSampleRate(sampleRate)
    updateSettings(settings)
  }
}

public final class AutoEQProcessor: BiquadProcessor {
  private var profile: AutoEQProfile?
  private var preampEnabled = true

  public init(sampleRate: Double = 48000) {
    super.init(sampleRate: sampleRate, maxSections: AutoEQProfile.maxFilters, category: "autoeq")
  }

  public func updateProfile(_ profile: AutoEQProfile?) {
    self.profile = profile
    rebuild()
  }

  public func setPreampEnabled(_ enabled: Bool) {
    preampEnabled = enabled
    rebuild()
  }

  public override func updateSampleRate(_ sampleRate: Double) {
    super.updateSampleRate(sampleRate)
    rebuild()
  }

  private func rebuild() {
    guard let profile else {
      precondition(replaceCoefficients(nil, sectionCount: 0) == FT_BIQUAD_OK)
      setEnabled(false)
      return
    }
    var coefficients = BiquadMath.coefficientsForAutoEQFilters(
      profile.filters, sampleRate: sampleRate, profileOptimizedRate: profile.optimizedSampleRate)
    if preampEnabled {
      if coefficients.isEmpty { coefficients = [1, 0, 0, 0, 0] }
      let gain = pow(10.0, Double(profile.preampDB) / 20.0)
      for index in 0..<3 { coefficients[index] *= gain }
    }
    precondition(
      replaceCoefficients(coefficients, sectionCount: coefficients.count / 5) == FT_BIQUAD_OK)
    setEnabled(true)
  }
}
