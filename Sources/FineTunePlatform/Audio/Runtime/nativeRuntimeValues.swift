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
}

enum NativeRouteAction: Sendable, Equatable {
  case startMuted, commit, update
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
    message = "Audio capture is unavailable in this build. Use the configured FineTune app or AudioProbe build."
  } else {
    switch kind {
    case .captureNotRequested:
      message = "Enable live audio processing before starting this route."
    case .permissionDenied:
      message = "Allow audio recording for FineTune in macOS Privacy & Security, then try again."
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

func nativeRouteObservation(
  key: AudioRouteKey, snapshot: FTNativeRouteSnapshot, phase: AudioRoutePhase? = nil
) -> AudioRouteObservation {
  AudioRouteObservation(
    key: key, phase: phase ?? nativeRoutePhase(snapshot.phase),
    acceptedRevision: snapshot.accepted_revision == 0 ? nil : snapshot.accepted_revision,
    appliedRevision: snapshot.applied_revision == 0 ? nil : snapshot.applied_revision,
    failure: snapshot.failure.kind == FT_NATIVE_NO_FAILURE ? nil : nativeRouteFailure(snapshot.failure),
    cleanupFailure: snapshot.cleanup_failure.kind == FT_NATIVE_NO_FAILURE
      ? nil : nativeRouteFailure(snapshot.cleanup_failure))
}
