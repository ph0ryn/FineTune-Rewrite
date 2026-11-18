import FineTuneControl
import FineTuneDomain
import Foundation

package enum RoutingRetirementFailureOrder: CaseIterable, Sendable {
  case errorBeforePending, errorAndRetiredBeforePending, errorBeforeRetiredResult,
    errorWithRetiredAfterPending
}

package enum RoutingDeferredOperation: String, CaseIterable, Sendable {
  case start, commit
}

private struct RoutingProbeWaitTimeout: Error, CustomStringConvertible {
  let waitedFor: String
  let timeout: Duration
  var description: String { "Timed out after \(timeout) waiting for \(waitedFor)" }
}

/// Settles one probe wait exactly once across an event, the deadline, or task cancellation.
private final class RoutingProbeWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var result: Result<Void, any Error>?

  func install(_ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    if let result = self.result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func succeed() {
    complete(.success(()))
  }

  func fail(_ error: any Error) {
    complete(.failure(error))
  }

  private func complete(_ result: Result<Void, any Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

@MainActor
package final class RoutingProbeRuntime: AudioRoutingRuntime {
  package private(set) var cleanupRetryRequests = 0
  package func requestCleanupRetry() { cleanupRetryRequests += 1 }
  package var requests: [AudioRouteRequest] = []
  package var handles: [RoutingProbeRoute] = []
  package var holdPreparation: Set<String> = []
  package var holdArmed: Set<String> = []
  package var holdRetirement: Set<String> = []
  package var holdRetirementReceipt: Set<String> = []
  package var committedBeforeRetirementReceipt = false
  private var retirementReceipts: [String: CheckedContinuation<AudioRetirementResult, Never>] = [:]
  package var holdUpdates: Set<String> = []
  package var holdOperations: [String: RoutingDeferredOperation] = [:]
  package var prepareFailure: AudioRouteFailure?
  package var retirementCallbackFailure: AudioRouteFailure?
  package var retirementCallbackUsesCleanup = false
  package var retirementFailureOrder: RoutingRetirementFailureOrder = .errorBeforePending
  package var startCleanupFailure: AudioRouteFailure?
  package var commitCleanupFailure: AudioRouteFailure?
  private static let waitTimeout: Duration = .seconds(5)
  private var occurred: Set<String> = []
  private var waiters: [String: [RoutingProbeWaiter]] = [:]
  private var preparationGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var updateGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var operationGates: [String: CheckedContinuation<Void, Never>] = [:]
  package init() {}
  package func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    requests.append(request)
    let route = RoutingProbeRoute(key: request.key, runtime: self)
    handles.append(route)
    emit("prepare:\(request.key.deviceUID)")
    emit("prepare:\(request.key.deviceUID):\(requests.count)")
    if holdPreparation.contains(request.key.deviceUID) {
      await withCheckedContinuation { preparationGates[request.key.deviceUID] = $0 }
    }
    if let prepareFailure { throw prepareFailure }
    return route
  }
  package func waitForRetirementReceipt(_ uid: String) async -> AudioRetirementResult {
    await withCheckedContinuation {
      retirementReceipts[uid] = $0
      emit("retirement-receipt:\(uid)")
    }
  }
  package func releaseRetirementReceipt(_ uid: String, result: AudioRetirementResult) {
    holdRetirementReceipt.remove(uid)
    retirementReceipts.removeValue(forKey: uid)?.resume(returning: result)
  }
  package func recordCommit() {
    if !retirementReceipts.isEmpty { committedBeforeRetirementReceipt = true }
  }
  package func handle(_ uid: String) -> RoutingProbeRoute? {
    handles.last { $0.key.deviceUID == uid }
  }
  package func emit(_ name: String) {
    occurred.insert(name)
    for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.succeed() }
  }
  package func wait(_ name: String) async throws {
    if occurred.contains(name) { return }
    let waiter = RoutingProbeWaiter()
    let timeout = Self.waitTimeout
    waiters[name, default: []].append(waiter)
    defer {
      waiters[name]?.removeAll { $0 === waiter }
      if waiters[name]?.isEmpty == true { waiters[name] = nil }
    }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
              waiter.install(continuation)
            }
          } onCancel: {
            waiter.fail(CancellationError())
          }
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw RoutingProbeWaitTimeout(waitedFor: name, timeout: timeout)
        }
        let result = await group.nextResult()
        group.cancelAll()
        while await group.nextResult() != nil {}
        try result?.get()
      }
    } catch {
      // Failure-path only: an unwinding wait must not strand controller tasks on gates the test
      // would otherwise release explicitly. The original timeout/cancellation error is preserved.
      releaseHeldGates()
      throw error
    }
  }
  /// Releases every held gate so fake operations suspended behind them drain after a failed wait.
  /// Pending retirement receipts drain with `.retired`; the original timeout/cancellation is
  /// rethrown and the test already fails. The successful path never calls this, so tests keep their
  /// explicit release ordering and explicit receipt results.
  private func releaseHeldGates() {
    holdPreparation.removeAll()
    holdUpdates.removeAll()
    holdOperations.removeAll()
    holdRetirementReceipt.removeAll()
    for gate in preparationGates.values { gate.resume() }
    preparationGates.removeAll()
    for gate in updateGates.values { gate.resume() }
    updateGates.removeAll()
    for gate in operationGates.values { gate.resume() }
    operationGates.removeAll()
    // Remove before resuming so a drained task can never resume the same receipt twice.
    let receipts = retirementReceipts
    retirementReceipts.removeAll()
    for receipt in receipts.values { receipt.resume(returning: .retired) }
  }
  package func releasePreparation(_ uid: String) {
    holdPreparation.remove(uid)
    preparationGates.removeValue(forKey: uid)?.resume()
  }
  package func suspendUpdate(_ uid: String) async {
    if holdUpdates.contains(uid) { await withCheckedContinuation { updateGates[uid] = $0 } }
  }
  package func releaseUpdates(_ uid: String) {
    holdUpdates.remove(uid)
    updateGates.removeValue(forKey: uid)?.resume()
  }
  package func suspendOperation(_ operation: RoutingDeferredOperation, uid: String) async {
    if holdOperations[uid] == operation {
      emit("deferred-\(operation.rawValue):\(uid)")
      await withCheckedContinuation { operationGates[uid] = $0 }
    }
  }
  package func releaseOperation(_ uid: String) {
    holdOperations[uid] = nil
    operationGates.removeValue(forKey: uid)?.resume()
  }
}

@MainActor
package final class RoutingProbeRoute: PreparedAudioRoute {
  package let key: AudioRouteKey
  package unowned let runtime: RoutingProbeRuntime
  package var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  package var commits: [AudioOutputState] = []
  package var updates: [AudioOutputState] = []
  package var nextUpdateReceipt: AudioRouteObservation?
  package var levels: [AudioOutputLevels] = []
  package var rendering = false
  // OS IO/tap muting survives closing render admission; only retirement actually stops it.
  package var ioRunning = false
  package var retired = false
  package var cancelled = false
  package var retirementAttempts = 0
  package var retirementError: AudioRouteFailure?
  package var cancellationsDuringRetirement = 0
  private var primaryFailure: AudioRouteFailure?
  package init(key: AudioRouteKey, runtime: RoutingProbeRuntime) {
    self.key = key
    self.runtime = runtime
  }
  package func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
    try checkAdmission()
    await runtime.suspendOperation(.start, uid: key.deviceUID)
    try checkAdmission(latchPrimary: true)
    if let failure = runtime.startCleanupFailure {
      onObservation?(AudioRouteObservation(key: key, phase: .started, cleanupFailure: failure))
    }
    ioRunning = true
    runtime.emit("started:\(key.deviceUID)")
    return AudioRouteObservation(
      key: key, phase: runtime.holdArmed.contains(key.deviceUID) ? .started : .armed,
      acceptedRevision: state.revision)
  }
  package func arm() { onObservation?(AudioRouteObservation(key: key, phase: .armed)) }
  package func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
    try checkAdmission()
    await runtime.suspendOperation(.commit, uid: key.deviceUID)
    try checkAdmission(latchPrimary: true)
    runtime.recordCommit()
    commits.append(state)
    ioRunning = true
    rendering = true
    if let failure = runtime.commitCleanupFailure {
      onObservation?(AudioRouteObservation(key: key, phase: .committed, cleanupFailure: failure))
    }
    runtime.emit("commit:\(key.deviceUID)")
    return AudioRouteObservation(key: key, phase: .committed, acceptedRevision: state.revision)
  }
  package func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    updates.append(state)
    runtime.emit("update:\(key.deviceUID):\(updates.count)")
    await runtime.suspendUpdate(key.deviceUID)
    if let receipt = nextUpdateReceipt {
      nextUpdateReceipt = nil
      return receipt
    }
    // Match the native adapter's post-await admission check without changing injected receipts.
    try checkAdmission()
    return AudioRouteObservation(key: key, phase: .accepted, acceptedRevision: state.revision)
  }
  private func checkAdmission(latchPrimary: Bool = false) throws {
    guard !cancelled && !retired else {
      let failure = AudioRouteFailure(
        kind: .cancelled, stage: "native", message: "The audio route was cancelled.")
      if latchPrimary {
        primaryFailure = failure
        runtime.emit("late-cancelled:\(key.deviceUID)")
      }
      throw failure
    }
  }
  package func requestLevels(_ levels: AudioOutputLevels) { self.levels.append(levels) }
  package func cancel() {
    // The production adapter's admission cancellation stops its current observation monitor.
    // Control must not repeat it after retirement has installed the PENDING progress monitor.
    if retirementAttempts > 0 && !retired { cancellationsDuringRetirement += 1 }
    cancelled = true
    rendering = false
  }
  package func retire() async -> AudioRetirementResult {
    cancel()
    retirementAttempts += 1
    runtime.emit("retire:\(key.deviceUID):\(retirementAttempts)")
    if let error = retirementError {
      onObservation?(AudioRouteObservation(key: key, phase: .failed, cleanupFailure: error))
      return .failed(error)
    }
    ioRunning = false
    if runtime.holdRetirementReceipt.contains(key.deviceUID) {
      finishRetirement()
      return await runtime.waitForRetirementReceipt(key.deviceUID)
    }
    runtime.emit("retire:\(key.deviceUID)")
    runtime.emit("retire:\(key.appIdentifier):\(key.deviceUID)")
    if runtime.holdRetirement.contains(key.deviceUID) && !retired {
      let earlyError = runtime.retirementFailureOrder != .errorWithRetiredAfterPending
      onObservation?(
        AudioRouteObservation(
          key: key, phase: .retiring,
          failure: earlyError && !runtime.retirementCallbackUsesCleanup
            ? runtime.retirementCallbackFailure : nil,
          cleanupFailure: earlyError && runtime.retirementCallbackUsesCleanup
            ? runtime.retirementCallbackFailure : nil))
      if runtime.retirementCallbackFailure != nil {
        if runtime.retirementFailureOrder == .errorAndRetiredBeforePending { finishRetirement() }
        if runtime.retirementFailureOrder == .errorBeforeRetiredResult {
          finishRetirement()
          return .retired
        }
      }
      return .pending
    }
    finishRetirement()
    return .retired
  }
  package func finishRetirement(
    failure: AudioRouteFailure? = nil, cleanupFailure: AudioRouteFailure? = nil
  ) {
    retired = true
    rendering = false
    ioRunning = false
    onObservation?(
      AudioRouteObservation(
        key: key, phase: .retired, failure: failure ?? primaryFailure,
        cleanupFailure: cleanupFailure))
    runtime.emit("retired:\(key.deviceUID)")
  }
}
