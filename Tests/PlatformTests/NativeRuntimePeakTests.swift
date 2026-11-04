import FineTuneControl
import NativeAudio
import Testing

@testable import FineTunePlatform

@Suite("Native runtime peak observation")
struct NativeRuntimePeakTests {
  private let key = AudioRouteKey(
    appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 9)

  @Test("Existing public observations leave an unavailable peak absent")
  func existingInitializerDefaultsPeakToNil() {
    let observation = AudioRouteObservation(key: key, phase: .committed)
    #expect(observation.peakLevel == nil)
  }

  @Test("A processed output peak reaches the public Control observation unchanged", arguments: [
    Float(0), 0.375, 1.25,
  ])
  func processedOutputPeakIsPreserved(peak: Float) {
    let observation = nativeRouteObservation(key: key, snapshot: appliedSnapshot(peak: peak))
    #expect(observation.key == key)
    #expect(observation.phase == .firstApplied)
    #expect(observation.acceptedRevision == 7)
    #expect(observation.appliedRevision == 7)
    #expect(observation.failure == nil)
    #expect(observation.cleanupFailure == nil)
    #expect(observation.peakLevel == peak)
  }

  @Test("Preparation and callback admission are not evidence of processed output")
  func unappliedNativePhasesHaveNoPeak() {
    for phase in [
      FT_NATIVE_PREPARED, FT_NATIVE_ACCEPTED, FT_NATIVE_STARTED, FT_NATIVE_ARMED,
      FT_NATIVE_COMMITTED, FT_NATIVE_RETIRING, FT_NATIVE_RETIRED, FT_NATIVE_ROUTE_FAILED,
    ] {
      var snapshot = appliedSnapshot(peak: 0)
      snapshot.phase = phase
      #expect(nativeRouteObservation(key: key, snapshot: snapshot).peakLevel == nil)
    }
  }

  @Test("Callback counts alone never turn an unprocessed zero into measured silence")
  func callbacksWithoutAppliedOutputHaveNoPeak() {
    var snapshot = appliedSnapshot(peak: 0)
    snapshot.phase = FT_NATIVE_COMMITTED
    snapshot.applied_revision = 0
    snapshot.processing_revision = 0
    snapshot.levels_revision = 0
    snapshot.callback_count = 500
    #expect(nativeRouteObservation(key: key, snapshot: snapshot).peakLevel == nil)

    snapshot.phase = FT_NATIVE_FIRST_APPLIED
    #expect(nativeRouteObservation(key: key, snapshot: snapshot).peakLevel == nil)

    snapshot = appliedSnapshot(peak: 0)
    snapshot.callback_count = 0
    #expect(nativeRouteObservation(key: key, snapshot: snapshot).peakLevel == nil)
  }

  @Test("Nonfinite and negative native peaks stay unavailable", arguments: [
    Float.nan, .infinity, -.infinity, -0.125,
  ])
  func invalidPeaksHaveNoValue(peak: Float) {
    let observation = nativeRouteObservation(key: key, snapshot: appliedSnapshot(peak: peak))
    #expect(observation.peakLevel == nil)
  }

  @Test("Failed and cleanup-pending snapshots do not publish an archived peak")
  func nativeFailuresHaveNoPeak() {
    let failure = FTNativeError(
      kind: FT_NATIVE_BINDING_CHANGED, operation: FT_NATIVE_CERTIFY_FORMAT, code: -17)
    var snapshot = appliedSnapshot()
    snapshot.failure = failure
    let failed = nativeRouteObservation(key: key, snapshot: snapshot)
    #expect(failed.failure?.kind == .bindingChanged)
    #expect(failed.peakLevel == nil)

    snapshot = appliedSnapshot()
    snapshot.cleanup_failure = failure
    let cleanup = nativeRouteObservation(key: key, snapshot: snapshot)
    #expect(cleanup.cleanupFailure?.kind == .bindingChanged)
    #expect(cleanup.peakLevel == nil)
  }

  @Test("Terminal Swift phase overrides invalidate an otherwise applied peak")
  func terminalPhaseOverridesHaveNoPeak() {
    for phase in [AudioRoutePhase.retiring, .retired, .failed] {
      let observation = nativeRouteObservation(key: key, snapshot: appliedSnapshot(), phase: phase)
      #expect(observation.phase == phase)
      #expect(observation.peakLevel == nil)
    }
  }

  @Test("An accepted update keeps the already processed native measurement")
  func acceptedUpdatePreservesAppliedPeak() {
    let observation = nativeRouteObservation(
      key: key, snapshot: appliedSnapshot(peak: 0.625), phase: .accepted)
    #expect(observation.phase == .accepted)
    #expect(observation.peakLevel == 0.625)
  }

  @Test("Public port equality notices a changed or missing measurement")
  func publicPortPreservesOptionalMeasurement() {
    let measured = AudioRouteObservation(key: key, phase: .firstApplied, peakLevel: 0.5)
    #expect(measured.peakLevel == 0.5)
    #expect(measured != AudioRouteObservation(key: key, phase: .firstApplied, peakLevel: 0))
    #expect(measured != AudioRouteObservation(key: key, phase: .firstApplied))
  }

  private func appliedSnapshot(peak: Float = 0.375) -> FTNativeRouteSnapshot {
    var snapshot = FTNativeRouteSnapshot()
    snapshot.phase = FT_NATIVE_FIRST_APPLIED
    snapshot.accepted_revision = 7
    snapshot.applied_revision = 7
    snapshot.processing_revision = 7
    snapshot.levels_revision = 7
    snapshot.callback_count = 4
    snapshot.peak = peak
    return snapshot
  }
}
