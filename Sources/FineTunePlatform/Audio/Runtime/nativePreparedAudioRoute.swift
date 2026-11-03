import FineTuneControl
import Foundation
import NativeAudio

@MainActor
final class NativePreparedAudioRoute: PreparedAudioRoute {
  let key: AudioRouteKey
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  private let owner: NativeRouteOwner
  private var monitor: NativeRouteMonitor?
  private var pollInFlight = false
  private var cancelled = false
  private var retiring = false
  private var retired = false
  private var epoch: UInt64 = 0
  private var sequence: UInt64 = 0
  private var deliveredSequence: UInt64 = 0
  private var latestFullRevision: UInt64
  private var lastObservation: AudioRouteObservation?

  init(key: AudioRouteKey, owner: NativeRouteOwner, initialRevision: UInt64) {
    self.key = key
    self.owner = owner
    self.latestFullRevision = initialRevision
    beginMonitoring()
  }

  deinit {
    monitor?.cancel()
    owner.cancel() // Admission only. NativeRouteOwner schedules all destruction on its NRT lane.
  }

  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    try await perform(.startMuted, state: state)
  }

  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    try await perform(.commit, state: state)
  }

  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    try await perform(.update, state: state)
  }

  func requestLevels(_ levels: AudioOutputLevels) {
    guard !cancelled && !retiring && !retired else { return }
    let native = FTNativeLevels(
      revision: levels.revision, target_gain: levels.effectiveGain, muted: levels.isMuted,
      loudness_volume: levels.effectiveLoudnessVolume)
    guard ft_native_route_request_levels(owner.pointer.value, native) == FT_NATIVE_OK else {
      let failure = AudioRouteFailure(
        stage: "levels", message: "Unable to publish the requested audio levels.")
      emit(AudioRouteObservation(key: key, phase: .failed, failure: failure), sequence: nextSequence())
      return
    }
  }

  func cancel() {
    cancelled = true
    epoch &+= 1
    monitor?.cancel()
    monitor = nil
    owner.cancel()
  }

  func retire() async -> AudioRetirementResult {
    if retired { return .retired }
    cancel()
    retiring = true
    beginMonitoring()
    let operationSequence = nextSequence()
    let result = await owner.perform { pointer in
      var error = FTNativeError()
      let result = ft_native_route_retire(pointer, &error)
      var snapshot = FTNativeRouteSnapshot()
      _ = ft_native_route_snapshot(pointer, &snapshot)
      return NativeRouteResult(result: result, snapshot: snapshot, failure: error)
    }
    return receiveRetirement(result, sequence: operationSequence)
  }

  private func perform(
    _ action: NativeRouteAction, state: AudioOutputState
  ) async throws -> AudioRouteObservation {
    guard !cancelled && !retiring && !retired && state.revision >= latestFullRevision else {
      throw cancellationFailure()
    }
    latestFullRevision = state.revision
    // This MainActor is the sole hot-lane producer. A late full state cannot replace newer
    // hot levels; native revision checks ignore stale tuples. Plain C full calls also work.
    requestLevels(AudioOutputLevels(
      revision: state.revision, effectiveGain: state.effectiveGain, isMuted: state.isMuted,
      effectiveLoudnessVolume: state.processing.loudnessVolume))
    let operationSequence = nextSequence()
    let result = await owner.perform { pointer in
      withNativeRuntimeState(state) { native in
        var error = FTNativeError()
        let result: FTNativeResult
        switch action {
        case .startMuted: result = ft_native_route_start_muted(pointer, native, &error)
        case .commit: result = ft_native_route_commit(pointer, native, &error)
        case .update: result = ft_native_route_update(pointer, native, &error)
        }
        var snapshot = FTNativeRouteSnapshot()
        _ = ft_native_route_snapshot(pointer, &snapshot)
        return NativeRouteResult(result: result, snapshot: snapshot, failure: error)
      }
    }
    guard !cancelled && !retiring && !retired else { throw cancellationFailure() }
    if result.result != FT_NATIVE_OK {
      let failure = nativeRouteFailure(result.failure)
      let observation = AudioRouteObservation(
        key: key, phase: .failed,
        acceptedRevision: result.snapshot.accepted_revision == 0 ? nil : result.snapshot.accepted_revision,
        appliedRevision: result.snapshot.applied_revision == 0 ? nil : result.snapshot.applied_revision,
        failure: failure,
        cleanupFailure: result.snapshot.cleanup_failure.kind == FT_NATIVE_NO_FAILURE
          ? nil : nativeRouteFailure(result.snapshot.cleanup_failure))
      emit(observation, sequence: operationSequence)
      throw failure
    }
    let observation = nativeRouteObservation(
      key: key, snapshot: result.snapshot, phase: action == .update ? .accepted : nil)
    emit(observation, sequence: operationSequence)
    return observation
  }

  private func beginMonitoring() {
    guard monitor == nil && !retired else { return }
    monitor = NativeRouteMonitor { [weak self] in
      Task { @MainActor [weak self] in await self?.poll() }
    }
  }

  private func poll() async {
    guard !pollInFlight && !retired && (!cancelled || retiring) else { return }
    pollInFlight = true
    let pollEpoch = epoch
    let operationSequence = nextSequence()
    let shouldRetire = retiring
    let result = await owner.perform { pointer in
      var error = FTNativeError()
      let result = shouldRetire ? ft_native_route_retire(pointer, &error) : FT_NATIVE_OK
      var snapshot = FTNativeRouteSnapshot()
      let snapshotResult = ft_native_route_snapshot(pointer, &snapshot)
      return NativeRouteResult(
        result: snapshotResult == FT_NATIVE_OK ? result : FT_NATIVE_FAILED,
        snapshot: snapshot, failure: error)
    }
    pollInFlight = false
    guard pollEpoch == epoch else { return }
    if shouldRetire {
      _ = receiveRetirement(result, sequence: operationSequence)
    } else if !cancelled {
      emit(nativeRouteObservation(key: key, snapshot: result.snapshot), sequence: operationSequence)
    }
  }

  private func receiveRetirement(
    _ result: NativeRouteResult, sequence: UInt64
  ) -> AudioRetirementResult {
    if result.result == FT_NATIVE_OK {
      retired = true
      monitor?.cancel()
      monitor = nil
      emit(nativeRouteObservation(key: key, snapshot: result.snapshot, phase: .retired), sequence: sequence)
      return .retired
    }
    if result.result == FT_NATIVE_PENDING {
      emit(nativeRouteObservation(key: key, snapshot: result.snapshot, phase: .retiring), sequence: sequence)
      return .pending
    }
    monitor?.cancel()
    monitor = nil
    let failure = nativeRouteFailure(result.failure)
    emit(nativeRouteObservation(key: key, snapshot: result.snapshot, phase: .failed), sequence: sequence)
    return .failed(failure)
  }

  private func nextSequence() -> UInt64 {
    sequence &+= 1
    return sequence
  }

  private func emit(_ observation: AudioRouteObservation, sequence: UInt64) {
    guard sequence >= deliveredSequence else { return }
    deliveredSequence = sequence
    guard observation != lastObservation else { return }
    lastObservation = observation
    onObservation?(observation)
  }

  private func cancellationFailure() -> AudioRouteFailure {
    AudioRouteFailure(kind: .cancelled, stage: "native", message: "The audio route was cancelled.")
  }
}
