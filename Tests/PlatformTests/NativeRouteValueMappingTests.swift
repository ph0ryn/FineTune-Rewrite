import FineTuneControl
import NativeAudio
import Testing

@testable import FineTunePlatform

// Failure-kind and operation tables cover the native values currently declared in
// NativeAudioRuntime.h. Imported plain C enums are non-exhaustive in Swift, so the tables need
// manual updates when the header grows. The unknown-operation fallback is asserted separately.
@Suite("Native route failure classification")
struct NativeRouteFailureClassificationTests {
  @Test(
    "Currently passed native failure kinds map to public classifications and generic messages",
    arguments: [
      (
        FT_NATIVE_UNAVAILABLE, AudioRouteFailureKind.unavailable,
        "The requested audio route is unavailable."
      ),
      (
        FT_NATIVE_CAPTURE_NOT_REQUESTED, AudioRouteFailureKind.captureNotRequested,
        "Enable live audio processing before starting this route."
      ),
      (
        FT_NATIVE_PERMISSION_DENIED, AudioRouteFailureKind.permissionDenied,
        "Allow audio recording for FineTune in macOS Privacy & Security, then try again."
      ),
      (
        FT_NATIVE_UNSUPPORTED, AudioRouteFailureKind.unsupported,
        "This route has an unsupported format, processing configuration, or input topology."
      ),
      (
        FT_NATIVE_BINDING_CHANGED, AudioRouteFailureKind.bindingChanged,
        "The app or output changed. Prepare a new audio route."
      ),
      (FT_NATIVE_CANCELLED, AudioRouteFailureKind.cancelled, "The audio route was cancelled."),
      (
        FT_NATIVE_FAILURE, AudioRouteFailureKind.nativeFailure,
        "Native audio could not complete the requested operation."
      ),
    ])
  func failureKinds(
    kind: FTNativeFailureKind, expected: AudioRouteFailureKind, message: String
  ) {
    let failure = nativeRouteFailure(FTNativeError(kind: kind, operation: FT_NATIVE_START, code: 0))
    #expect(failure.kind == expected)
    #expect(failure.stage == "start")
    #expect(failure.code == nil)
    #expect(failure.message == message)
  }

  @Test(
    "Currently declared native operations name their public stages",
    arguments: [
      (FT_NATIVE_INPUT, "input"),
      (FT_NATIVE_USAGE_DESCRIPTION, "usageDescription"),
      (FT_NATIVE_RESOLVE_PROCESS, "resolveProcess"),
      (FT_NATIVE_RESOLVE_OUTPUT, "resolveOutput"),
      (FT_NATIVE_CREATE_TAP, "createTap"),
      (FT_NATIVE_READ_TAP, "inspectTap"),
      (FT_NATIVE_CREATE_AGGREGATE, "createAggregate"),
      (FT_NATIVE_CREATE_IOPROC, "registerCallback"),
      (FT_NATIVE_CERTIFY_FORMAT, "certifyFormat"),
      (FT_NATIVE_INSTALL_LISTENERS, "installListeners"),
      (FT_NATIVE_PREPARE_DSP, "prepareDSP"),
      (FT_NATIVE_START, "start"),
      (FT_NATIVE_PROCESS, "process"),
      (FT_NATIVE_STOP, "stop"),
      (FT_NATIVE_DESTROY_IOPROC, "destroyCallback"),
      (FT_NATIVE_REMOVE_LISTENER, "removeListener"),
      (FT_NATIVE_DESTROY_AGGREGATE, "destroyAggregate"),
      (FT_NATIVE_AWAIT_AGGREGATE_REMOVAL, "awaitAggregateRemoval"),
      (FT_NATIVE_DESTROY_TAP, "destroyTap"),
    ])
  func operationStages(operation: FTNativeOperation, stage: String) {
    let failure = nativeRouteFailure(
      FTNativeError(kind: FT_NATIVE_FAILURE, operation: operation, code: 7))
    #expect(failure.kind == .nativeFailure)
    #expect(failure.stage == stage)
    #expect(failure.code == 7)
  }

  @Test("An operation outside the known native set still names a stage explicitly")
  func unknownOperationStaysExplicit() {
    let failure = nativeRouteFailure(
      FTNativeError(
        kind: FT_NATIVE_FAILURE, operation: FTNativeOperation(rawValue: 999), code: 1))
    #expect(failure.kind == .nativeFailure)
    #expect(failure.stage == "native")
    #expect(failure.code == 1)
  }
}

@Suite("Native route observation mapping")
struct NativeRouteObservationMappingTests {
  private let key = AudioRouteKey(
    appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 1)

  @Test("An unknown native phase fails closed with zero revisions reported as absent")
  func unknownPhaseAndZeroRevisions() {
    var snapshot = FTNativeRouteSnapshot()
    snapshot.phase = FTNativePhase(rawValue: 99)
    snapshot.failure = FTNativeError(
      kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_START, code: 1)
    let unknown = nativeRouteObservation(key: key, snapshot: snapshot)
    #expect(unknown.key == key)
    #expect(unknown.phase == .failed)
    #expect(unknown.acceptedRevision == nil)
    #expect(unknown.appliedRevision == nil)
    #expect(unknown.failure?.kind == .nativeFailure)
    #expect(unknown.peakLevel == nil)
  }

  @Test("Zero revisions are absent while nonzero revisions are preserved exactly")
  func revisionPresenceIsExplicit() {
    var snapshot = FTNativeRouteSnapshot()
    snapshot.phase = FT_NATIVE_PREPARED
    let zero = nativeRouteObservation(key: key, snapshot: snapshot)
    #expect(zero.phase == .prepared)
    #expect(zero.acceptedRevision == nil)
    #expect(zero.appliedRevision == nil)

    snapshot.accepted_revision = 7
    snapshot.applied_revision = 9
    snapshot.phase = FT_NATIVE_ACCEPTED
    let revisions = nativeRouteObservation(key: key, snapshot: snapshot)
    #expect(revisions.phase == .accepted)
    #expect(revisions.acceptedRevision == 7)
    #expect(revisions.appliedRevision == 9)
  }
}
