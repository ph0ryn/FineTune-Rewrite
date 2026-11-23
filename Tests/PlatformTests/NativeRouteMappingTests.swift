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
        "Allow audio recording for FineTune-Rewrite in macOS Privacy & Security, then try again."
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

@Suite("Native route failure messages")
struct NativeRouteFailureMessageTests {
  @Test("Each resolveOutput rejection names the observed condition")
  func resolveOutputRejectionsAreSpecific() {
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

@Suite("Native invalidation diagnostic metadata")
struct NativeInvalidationDiagnosticTests {
  @Test("Property diagnostics distinguish an absent address from a real zero-valued address")
  func propertyAddressPresenceIsExplicit() {
    var value = FTNativeInvalidationSnapshot()
    value.source = FT_NATIVE_INVALIDATION_PROPERTY
    value.reason = FT_NATIVE_INVALIDATION_PROPERTY_NOTIFICATION
    value.property_object_id = 801
    value.property_count = 3
    value.has_property_address = true
    value.property_selector = 0x736C_6179
    value.property_scope = 0x6F75_7470
    value.property_element = 2
    let detail = nativeInvalidationDescription(value)
    #expect(detail.contains("reason=propertyNotification(1)"))
    #expect(detail.contains("object=801 count=3 hasAddress=true"))
    #expect(detail.contains("selector=0x736c6179 scope=0x6f757470 element=2"))
    value.has_property_address = false
    let absent = nativeInvalidationDescription(value)
    #expect(absent.contains("hasAddress=false"))
    #expect(!absent.contains("selector=") && !absent.contains("scope="))
  }

  @Test("All IO rejection categories retain device identity without samples or raw pointers")
  func ioRejectionNamesAreDistinct() {
    let reasons: [(FTNativeInvalidationReason, String)] = [
      (FT_NATIVE_INVALIDATION_IO_WRONG_DEVICE, "wrongDevice"),
      (FT_NATIVE_INVALIDATION_IO_INPUT_SHAPE, "inputShape"),
      (FT_NATIVE_INVALIDATION_IO_OUTPUT_SHAPE, "outputShape"),
      (FT_NATIVE_INVALIDATION_IO_ABSENT_OUTPUT, "absentOutput"),
      (FT_NATIVE_INVALIDATION_IO_FRAME_MISMATCH, "frameMismatch"),
    ]
    for (reason, name) in reasons {
      var value = FTNativeInvalidationSnapshot()
      value.source = FT_NATIVE_INVALIDATION_IO
      value.reason = reason
      value.observed_device_id = 901
      value.expected_device_id = 902
      let detail = nativeInvalidationDescription(value)
      #expect(detail.contains("reason=\(name)(\(reason.rawValue))"))
      #expect(detail.contains("observedDevice=901 expectedDevice=902"))
      #expect(!detail.contains("selector=") && !detail.contains("pointer="))
    }
  }
}
