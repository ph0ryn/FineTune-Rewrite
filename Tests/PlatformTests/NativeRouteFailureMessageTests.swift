import FineTuneControl
import NativeAudio
import Testing

@testable import FineTunePlatform

@Suite("Native route failure messages")
struct NativeRouteFailureMessageTests {
  @Test("Each resolveOutput rejection names the observed condition")
  func resolveOutputRejectionsAreSpecific() {
    // Messages are the only evidence left after the device state settles, so a rejection that
    // reads as an unsupported format regardless of its cause cannot be acted on.
    let expectations: [(code: Int32, fragment: String)] = [
      (Int32(FT_NATIVE_OUTPUT_IDENTITY_MISMATCH), "no longer resolves"),
      (Int32(FT_NATIVE_OUTPUT_CAPTURE_CHANNELS), "input channels"),
      (Int32(FT_NATIVE_OUTPUT_AGGREGATE), "aggregate device"),
      (Int32(FT_NATIVE_OUTPUT_STEREO_ORDER), "1/2 stereo"),
      (Int32(FT_NATIVE_OUTPUT_LAYOUT), "packed stereo float32"),
      (Int32(FT_NATIVE_OUTPUT_RATE_MISMATCH), "sample rates disagree"),
    ]
    for expectation in expectations {
      let failure = nativeRouteFailure(
        FTNativeError(
          kind: FT_NATIVE_UNSUPPORTED, operation: FT_NATIVE_RESOLVE_OUTPUT,
          code: expectation.code))
      #expect(failure.kind == .unsupported)
      #expect(failure.stage == "resolveOutput")
      #expect(failure.code == expectation.code)
      #expect(failure.message.contains(expectation.fragment))
    }
  }

  @Test("An unidentified resolveOutput code keeps the generic message")
  func unidentifiedRejectionStaysGeneric() {
    let failure = nativeRouteFailure(
      FTNativeError(
        kind: FT_NATIVE_UNSUPPORTED, operation: FT_NATIVE_RESOLVE_OUTPUT, code: -5101))
    #expect(failure.kind == .unsupported)
    #expect(
      failure.message
        == "This route has an unsupported format, processing configuration, or input topology.")
  }

  @Test("Other operations keep their existing message")
  func otherOperationsAreUnchanged() {
    let failure = nativeRouteFailure(
      FTNativeError(
        kind: FT_NATIVE_UNSUPPORTED, operation: FT_NATIVE_CERTIFY_FORMAT, code: -5101))
    #expect(failure.stage == "certifyFormat")
    #expect(
      failure.message
        == "This route has an unsupported format, processing configuration, or input topology.")
  }
}
