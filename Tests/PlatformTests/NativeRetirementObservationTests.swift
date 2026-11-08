import FineTuneControl
import NativeAudio
import Testing

@testable import FineTunePlatform

@Suite("Native retirement attempt observations")
struct NativeRetirementObservationTests {
  private let key = AudioRouteKey(
    appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 9)
  private let historical = FTNativeError(
    kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_STOP, code: 560_227_702)

  @Test("Pending and successful retirement do not replay historical cleanup as a new failure")
  func historicalCleanupIsNotAnAttemptFailure() {
    for status in [FT_NATIVE_PENDING, FT_NATIVE_OK] {
      var snapshot = FTNativeRouteSnapshot()
      snapshot.phase = FT_NATIVE_RETIRING
      snapshot.cleanup_failure = historical
      snapshot.failure = FTNativeError(
        kind: FT_NATIVE_BINDING_CHANGED, operation: FT_NATIVE_CERTIFY_FORMAT, code: -5101)
      let result = NativeRouteResult(result: status, snapshot: snapshot, failure: FTNativeError())
      let observation = nativeRetirementObservation(key: key, result: result)
      #expect(observation.key == key)
      #expect(observation.phase == (status == FT_NATIVE_OK ? .retired : .retiring))
      #expect(observation.cleanupFailure == nil)
      #expect(observation.failure?.kind == .bindingChanged)
      #expect(observation.peakLevel == nil)
      // Native snapshots retain the diagnostic; normalization only changes this operation's event.
      #expect(result.snapshot.cleanup_failure.code == 560_227_702)
    }
  }

  @Test("A failed retirement emits this operation's error, even when the snapshot latches another")
  func currentRetirementErrorIsAuthoritative() {
    for error in [
      historical,
      FTNativeError(
        kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_DESTROY_IOPROC, code: -7302),
    ] {
      var snapshot = FTNativeRouteSnapshot()
      snapshot.cleanup_failure = historical
      let observation = nativeRetirementObservation(
        key: key,
        result: NativeRouteResult(result: FT_NATIVE_FAILED, snapshot: snapshot, failure: error))
      #expect(observation.phase == .failed)
      #expect(observation.cleanupFailure == nativeRouteFailure(error))
    }
  }
}
