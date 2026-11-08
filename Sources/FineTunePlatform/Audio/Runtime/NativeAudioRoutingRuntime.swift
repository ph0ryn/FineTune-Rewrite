import Dispatch
import FineTuneControl
import Foundation
import NativeAudio

/// MainActor resolution comes from the same shared process producer used by the UI/Control.
/// Construction is passive. No private process discovery, helper heuristic, permission query,
/// tap, aggregate or IOProc is performed until an explicitly requested preparation.
@MainActor
public final class NativeAudioRoutingRuntime: AudioRoutingRuntime {
  private let resolveApp: @MainActor (String, UInt64) throws -> AudioApp
  private let cleanupOwnerID: UUID
  private let retirementPool: NativeRetirementPool
  private var cleanupRetry: Task<Void, Never>?
  /// Historical cleanup diagnostic, not evidence of currently unresolved cleanup debt.
  public private(set) var lastCleanupFailure: AudioRouteObservation?
  /// Current cleanup debt, removed only after that route's native release succeeds.
  public private(set) var unresolvedCleanupFailures: [AudioRouteKey: AudioRouteObservation] = [:]
  public var onCleanupFailure: (@MainActor (AudioRouteObservation) -> Void)?
  /// Notifies when keyed cleanup debt changes, including a matching successful release.
  public var onCleanupChange: (@MainActor () -> Void)?

  public convenience init(resolveApp: @escaping @MainActor (String, UInt64) throws -> AudioApp) {
    self.init(resolveApp: resolveApp, retirementPool: .shared, cleanupOwnerID: UUID())
  }

  init(
    resolveApp: @escaping @MainActor (String, UInt64) throws -> AudioApp,
    retirementPool: NativeRetirementPool, cleanupOwnerID: UUID
  ) {
    self.resolveApp = resolveApp
    self.retirementPool = retirementPool
    self.cleanupOwnerID = cleanupOwnerID
  }

  public func requestCleanupRetry() {
    guard cleanupRetry == nil else { return }
    let pool = retirementPool
    let id = cleanupOwnerID
    cleanupRetry = Task { [weak self] in
      await pool.retryFailed(cleanupOwnerID: id)
      self?.cleanupRetry = nil
    }
  }

  public func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    guard case .userInitiated(let session) = request.captureIntent, session != 0 else {
      throw AudioRouteFailure(
        kind: .captureNotRequested, stage: "prepare",
        message: "Enable live audio processing before starting this route.")
    }
    await cleanupRetry?.value
    guard !Task.isCancelled else { throw cancelledPreparation() }
    let app: AudioApp
    do {
      app = try resolveApp(request.key.appIdentifier, request.processRevision)
    } catch AudioAppObservationResolutionError.unavailable {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "resolveProcess", message: "The selected app is unavailable.")
    } catch AudioAppObservationResolutionError.bindingChanged {
      throw AudioRouteFailure(
        kind: .bindingChanged, stage: "resolveProcess",
        message: "The app's process group changed. Prepare a new audio route.")
    } catch let failure as AudioRouteFailure {
      throw failure
    } catch {
      throw AudioRouteFailure(
        stage: "resolveProcess", message: "Unable to resolve the app's process group: \(error)")
    }
    let objects = app.processObjectIDs  // Copy values only; no AudioApp/NSImage crosses the lane.
    guard !objects.isEmpty else {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "resolveProcess",
        message: "The selected app has no current audio process.")
    }
    guard !Task.isCancelled else { throw cancelledPreparation() }
    let lane = DispatchQueue(label: "FineTune.NativeAudio.Route", qos: .userInitiated)
    let diagnosticsEnabled =
      ProcessInfo.processInfo.environment["FINETUNE_AUDIO_DIAGNOSTICS"] == "1"
    let reportCleanup: @Sendable (FTNativeError) -> Void = { [weak self] error in
      let failure = nativeRouteFailure(error)
      Task { @MainActor [weak self] in self?.recordCleanup(request.key, failure: failure) }
    }
    let reportRetired: @Sendable () -> Void = { [weak self] in
      Task { @MainActor [weak self] in self?.recordRetired(request.key) }
    }
    let packet: NativePreparationPacket = await withCheckedContinuation { continuation in
      lane.async {
        let packet = withNativeRuntimeState(request.initialState) { initial in
          objects.withUnsafeBufferPointer { processes in
            request.key.deviceUID.withCString { uid in
              var native = FTNativeRouteRequest(
                output_uid: uid, process_objects: processes.baseAddress,
                process_count: UInt32(processes.count), process_revision: request.processRevision,
                route_generation: request.key.generation, capture_session: session,
                initial_state: initial.pointee)
              var pointer: OpaquePointer?
              var error = FTNativeError()
              var result = ft_native_route_prepare(&native, &pointer, &error)
              if result == FT_NATIVE_OK, let pointer, diagnosticsEnabled {
                result = ft_native_route_enable_timing(pointer, &error)
              }
              var snapshot = FTNativeRouteSnapshot()
              if let pointer { _ = ft_native_route_snapshot(pointer, &snapshot) }
              return NativePreparationPacket(
                result: result, pointer: pointer.map { NativeRoutePointer(value: $0) },
                snapshot: snapshot, failure: error)
            }
          }
        }
        continuation.resume(returning: packet)
      }
    }
    if packet.snapshot.cleanup_failure.kind != FT_NATIVE_NO_FAILURE {
      recordCleanup(request.key, failure: nativeRouteFailure(packet.snapshot.cleanup_failure))
    }
    if packet.result != FT_NATIVE_OK || Task.isCancelled {
      if let pointer = packet.pointer {
        ft_native_route_cancel(pointer.value)
        retirementPool.adopt(
          pointer, lane: lane, cleanupOwnerID: cleanupOwnerID,
          reportCleanup: reportCleanup, reportRetired: reportRetired)
      }
      if Task.isCancelled { throw cancelledPreparation() }
      throw nativeRouteFailure(packet.failure)
    }
    guard let pointer = packet.pointer else {
      throw AudioRouteFailure(
        stage: "prepare", message: "Native audio returned success without an owned route.")
    }
    let owner = NativeRouteOwner(
      pointer: pointer, lane: lane, cleanupOwnerID: cleanupOwnerID, retirementPool: retirementPool,
      reportCleanup: reportCleanup, reportRetired: reportRetired)
    return NativePreparedAudioRoute(
      key: request.key, owner: owner, initialRevision: request.initialState.revision)
  }

  func recordCleanup(_ key: AudioRouteKey, failure: AudioRouteFailure) {
    let observation = AudioRouteObservation(key: key, phase: .failed, cleanupFailure: failure)
    let changed = unresolvedCleanupFailures[key] != observation
    unresolvedCleanupFailures[key] = observation
    if observation != lastCleanupFailure {
      lastCleanupFailure = observation
      onCleanupFailure?(observation)
    }
    if changed { onCleanupChange?() }
  }

  /// Called only after the retirement pool has successfully released the native owner.
  func recordRetired(_ key: AudioRouteKey) {
    guard unresolvedCleanupFailures.removeValue(forKey: key) != nil else { return }
    onCleanupChange?()
  }

  private func cancelledPreparation() -> AudioRouteFailure {
    AudioRouteFailure(kind: .cancelled, stage: "prepare", message: "The audio route was cancelled.")
  }
}

private struct NativePreparationPacket: @unchecked Sendable {
  let result: FTNativeResult
  let pointer: NativeRoutePointer?
  let snapshot: FTNativeRouteSnapshot
  let failure: FTNativeError
}
