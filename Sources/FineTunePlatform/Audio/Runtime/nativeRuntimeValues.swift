import FineTuneControl
import FineTuneDomain
import NativeAudio

// C storage is borrowed only inside this NRT closure. The native prepare/update operation
// copies values and owns every processor; Swift never owns or enters an audio callback.
func withNativeRuntimeState<Result>(
  _ state: AudioOutputState, _ body: (UnsafePointer<FTNativeOutputState>) -> Result
) -> Result {
  let processing = state.processing
  let gains = processing.eqSettings.isEnabled ? processing.eqSettings.clampedGains : []
  let profile = processing.autoEQProfile
  let filters = BiquadMath.nativeFilters(profile?.filters ?? [])
  return gains.withUnsafeBufferPointer { gainBuffer in
    filters.withUnsafeBufferPointer { filterBuffer in
      let nativeProcessing = FTNativeProcessingState(
        eq_gains_db: gains.isEmpty ? nil : gainBuffer.baseAddress,
        eq_gain_count: UInt32(gains.count), has_profile: profile != nil,
        profile_filters: filters.isEmpty ? nil : filterBuffer.baseAddress,
        profile_filter_count: UInt32(filters.count),
        profile_optimized_rate: profile?.optimizedSampleRate ?? 0,
        profile_preamp_db: profile?.preampDB ?? 0,
        profile_preamp_enabled: processing.autoEQPreampEnabled,
        loudness_equalizer: processing.loudnessEqualizerSettings.nativeValue,
        loudness_compensation_enabled: processing.loudnessCompensationEnabled,
        loudness_volume: processing.loudnessVolume)
      var native = FTNativeOutputState(
        revision: state.revision, target_gain: state.effectiveGain,
        muted: state.isMuted, processing: nativeProcessing)
      return withUnsafePointer(to: &native, body)
    }
  }
}

struct NativeRoutePointer: @unchecked Sendable {
  let value: OpaquePointer
}

struct NativeRouteResult: @unchecked Sendable {
  let result: FTNativeResult
  let snapshot: FTNativeRouteSnapshot
  let failure: FTNativeError
  let timing: FTNativeTimingSnapshot?
  let invalidation: FTNativeInvalidationSnapshot?

  init(
    result: FTNativeResult, snapshot: FTNativeRouteSnapshot, failure: FTNativeError,
    timing: FTNativeTimingSnapshot? = nil, invalidation: FTNativeInvalidationSnapshot? = nil
  ) {
    self.result = result
    self.snapshot = snapshot
    self.failure = failure
    self.timing = timing
    self.invalidation = invalidation
  }
}

// Passive NRT read on the same owner lane. A missing result is reported by the diagnostic sink.
func nativeTimingSnapshot(_ pointer: OpaquePointer, enabled: Bool) -> FTNativeTimingSnapshot? {
  guard enabled else { return nil }
  var timing = FTNativeTimingSnapshot()
  guard ft_native_route_timing_snapshot(pointer, &timing) == FT_NATIVE_OK else { return nil }
  return timing
}

enum NativeRouteAction: Sendable, Equatable {
  case startMuted, commit, update
}

// A resolveOutput rejection reports the observed condition. Left generic, every rejection reads as
// an unsupported format and a state that only exists while the device is settling cannot be acted on.
private func resolveOutputMessage(_ error: FTNativeError) -> String? {
  guard error.operation == FT_NATIVE_RESOLVE_OUTPUT, error.kind == FT_NATIVE_UNSUPPORTED else {
    return nil
  }
  switch Int(error.code) {
  case FT_NATIVE_OUTPUT_IDENTITY_MISMATCH:
    return "The requested output no longer resolves to that audio device. Choose the output again."
  case FT_NATIVE_OUTPUT_CAPTURE_CHANNELS:
    return "This output also exposes input channels, so it cannot host a playback-only route."
  case FT_NATIVE_OUTPUT_AGGREGATE:
    return "This output is an aggregate device. Choose the physical output instead."
  case FT_NATIVE_OUTPUT_STEREO_ORDER:
    return "This output does not report the standard 1/2 stereo channel order."
  case FT_NATIVE_OUTPUT_LAYOUT:
    return "This output is not packed stereo float32, so it cannot host an audio route."
  case FT_NATIVE_OUTPUT_RATE_MISMATCH:
    return
      "This output's nominal and stream sample rates disagree, so it is changing format. Try again."
  default:
    return nil
  }
}

func nativeRouteFailure(_ error: FTNativeError) -> AudioRouteFailure {
  let kind: AudioRouteFailureKind
  switch error.kind {
  case FT_NATIVE_UNAVAILABLE: kind = .unavailable
  case FT_NATIVE_CAPTURE_NOT_REQUESTED: kind = .captureNotRequested
  case FT_NATIVE_PERMISSION_DENIED: kind = .permissionDenied
  case FT_NATIVE_UNSUPPORTED: kind = .unsupported
  case FT_NATIVE_BINDING_CHANGED: kind = .bindingChanged
  case FT_NATIVE_CANCELLED: kind = .cancelled
  default: kind = .nativeFailure
  }
  let stage: String
  switch error.operation {
  case FT_NATIVE_INPUT: stage = "input"
  case FT_NATIVE_USAGE_DESCRIPTION: stage = "usageDescription"
  case FT_NATIVE_RESOLVE_PROCESS: stage = "resolveProcess"
  case FT_NATIVE_RESOLVE_OUTPUT: stage = "resolveOutput"
  case FT_NATIVE_CREATE_TAP: stage = "createTap"
  case FT_NATIVE_READ_TAP: stage = "inspectTap"
  case FT_NATIVE_CREATE_AGGREGATE: stage = "createAggregate"
  case FT_NATIVE_CREATE_IOPROC: stage = "registerCallback"
  case FT_NATIVE_CERTIFY_FORMAT: stage = "certifyFormat"
  case FT_NATIVE_INSTALL_LISTENERS: stage = "installListeners"
  case FT_NATIVE_PREPARE_DSP: stage = "prepareDSP"
  case FT_NATIVE_START: stage = "start"
  case FT_NATIVE_PROCESS: stage = "process"
  case FT_NATIVE_STOP: stage = "stop"
  case FT_NATIVE_DESTROY_IOPROC: stage = "destroyCallback"
  case FT_NATIVE_REMOVE_LISTENER: stage = "removeListener"
  case FT_NATIVE_DESTROY_AGGREGATE: stage = "destroyAggregate"
  case FT_NATIVE_AWAIT_AGGREGATE_REMOVAL: stage = "awaitAggregateRemoval"
  case FT_NATIVE_DESTROY_TAP: stage = "destroyTap"
  default: stage = "native"
  }
  let message: String
  if error.operation == FT_NATIVE_USAGE_DESCRIPTION {
    message =
      "Audio capture is unavailable in this build. Use the configured FineTune-Rewrite app or AudioProbe build."
  } else if let rejected = resolveOutputMessage(error) {
    message = rejected
  } else {
    switch kind {
    case .captureNotRequested:
      message = "Enable live audio processing before starting this route."
    case .permissionDenied:
      message =
        "Allow audio recording for FineTune-Rewrite in macOS Privacy & Security, then try again."
    case .unsupported:
      message = "This route has an unsupported format, processing configuration, or input topology."
    case .bindingChanged:
      message = "The app or output changed. Prepare a new audio route."
    case .cancelled:
      message = "The audio route was cancelled."
    case .unavailable:
      message = "The requested audio route is unavailable."
    case .nativeFailure:
      message = "Native audio could not complete the requested operation."
    }
  }
  return AudioRouteFailure(
    kind: kind, stage: stage, code: error.code == 0 ? nil : error.code, message: message)
}

func nativeRoutePhase(_ phase: FTNativePhase) -> AudioRoutePhase {
  switch phase {
  case FT_NATIVE_PREPARED: .prepared
  case FT_NATIVE_ACCEPTED: .accepted
  case FT_NATIVE_STARTED: .started
  case FT_NATIVE_ARMED: .armed
  case FT_NATIVE_COMMITTED: .committed
  case FT_NATIVE_FIRST_APPLIED: .firstApplied
  case FT_NATIVE_RETIRING: .retiring
  case FT_NATIVE_RETIRED: .retired
  default: .failed
  }
}

func nativeRetirementObservation(
  key: AudioRouteKey, result: NativeRouteResult
) -> AudioRouteObservation {
  let phase: AudioRoutePhase
  switch result.result {
  case FT_NATIVE_OK: phase = .retired
  case FT_NATIVE_PENDING: phase = .retiring
  default: phase = .failed
  }
  var snapshot = result.snapshot
  // Native snapshots archive the first cleanup diagnostic. A retirement event reports this
  // invocation's outcome instead, or a later successful retry would replay the old error.
  snapshot.cleanup_failure = result.result == FT_NATIVE_FAILED ? result.failure : FTNativeError()
  return nativeRouteObservation(key: key, snapshot: snapshot, phase: phase)
}

func nativeRouteObservation(
  key: AudioRouteKey, snapshot: FTNativeRouteSnapshot, phase: AudioRoutePhase? = nil
) -> AudioRouteObservation {
  let observedPhase = phase ?? nativeRoutePhase(snapshot.phase)
  // Callback counts include disabled/empty taps. First-applied requires a processed, permitted
  // buffer; the peak is its latest observed post-output amplitude, not a freshness guarantee.
  let hasPeak =
    snapshot.phase == FT_NATIVE_FIRST_APPLIED && snapshot.applied_revision > 0
    && snapshot.callback_count > 0 && snapshot.failure.kind == FT_NATIVE_NO_FAILURE
    && snapshot.cleanup_failure.kind == FT_NATIVE_NO_FAILURE
    && observedPhase != .retiring && observedPhase != .retired && observedPhase != .failed
    && snapshot.peak.isFinite && snapshot.peak >= 0
  return AudioRouteObservation(
    key: key, phase: observedPhase,
    acceptedRevision: snapshot.accepted_revision == 0 ? nil : snapshot.accepted_revision,
    appliedRevision: snapshot.applied_revision == 0 ? nil : snapshot.applied_revision,
    failure: snapshot.failure.kind == FT_NATIVE_NO_FAILURE
      ? nil : nativeRouteFailure(snapshot.failure),
    cleanupFailure: snapshot.cleanup_failure.kind == FT_NATIVE_NO_FAILURE
      ? nil : nativeRouteFailure(snapshot.cleanup_failure), peakLevel: hasPeak ? snapshot.peak : nil
  )
}
