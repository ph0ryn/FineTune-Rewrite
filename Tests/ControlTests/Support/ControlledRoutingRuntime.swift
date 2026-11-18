import FineTuneControl
import FineTuneDomain
import Foundation

enum ControlRetirementFailureOrder: CaseIterable, Sendable {
  case errorBeforePending, errorAndRetiredBeforePending, errorBeforeRetiredResult,
    errorWithRetiredAfterPending
}

enum ControlDeferredOperation: String, CaseIterable, Sendable {
  case start, commit
}

private struct ControlledRuntimeTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  let timeout: Duration
  var description: String { "Timed out after \(timeout) waiting for \(waitedFor)" }
}

private final class ControlledRuntimeWaiter: @unchecked Sendable {
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

  func succeed() { complete(.success(())) }
  func fail(_ error: any Error) { complete(.failure(error)) }

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

/// Unified controllable `AudioRoutingRuntime` double for Control state-machine tests.
@MainActor
final class ControlledRoutingRuntime: AudioRoutingRuntime {
  private(set) var cleanupRetryRequests = 0
  var requests: [AudioRouteRequest] = []
  var handles: [ControlledPreparedRoute] = []
  private(set) var maximumOutstandingPreparations = 0
  private(set) var cancelledHeldPreparation = false
  var committedBeforeRetirementReceipt = false

  var holdPreparation: Set<String> = []
  var holdArmed: Set<String> = []
  var holdRetirement: Set<String> = []
  var holdRetirementReceipt: Set<String> = []
  var holdUpdates: Set<String> = []
  var holdOperations: [String: ControlDeferredOperation] = [:]

  var prepareFailure: AudioRouteFailure?
  /// Optional per-request override; when nil, uses `prepareFailure` / normal route creation.
  var onPrepareRequest: (@MainActor (AudioRouteRequest, Int) async throws -> AudioRouteFailure?)?
  var retirementCallbackFailure: AudioRouteFailure?
  var retirementCallbackUsesCleanup = false
  var retirementFailureOrder: ControlRetirementFailureOrder = .errorBeforePending
  var startCleanupFailure: AudioRouteFailure?
  var commitCleanupFailure: AudioRouteFailure?

  private static let waitTimeout: Duration = .seconds(5)
  private var outstandingPreparations = 0
  private var occurred: Set<String> = []
  private var waiters: [String: [ControlledRuntimeWaiter]] = [:]
  private var preparationGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var updateGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var operationGates: [String: CheckedContinuation<Void, Never>] = [:]
  private var retirementReceipts: [String: CheckedContinuation<AudioRetirementResult, Never>] = [:]
  private var preparationCountWaiters: [(target: Int, waiter: ControlledRuntimeWaiter)] = []

  func requestCleanupRetry() { cleanupRetryRequests += 1 }

  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    let attemptIndex = requests.count
    requests.append(request)
    outstandingPreparations += 1
    maximumOutstandingPreparations = max(maximumOutstandingPreparations, outstandingPreparations)
    defer { outstandingPreparations -= 1 }

    emit("prepare:\(request.key.deviceUID)")
    emit("prepare:\(request.key.deviceUID):\(requests.count)")
    resumePreparationCountWaiters()

    if holdPreparation.remove(request.key.deviceUID) != nil {
      await withCheckedContinuation { preparationGates[request.key.deviceUID] = $0 }
      if Task.isCancelled { cancelledHeldPreparation = true }
    }
    if let onPrepareRequest {
      if let customFailure = try await onPrepareRequest(request, attemptIndex) {
        throw customFailure
      }
    }
    if let prepareFailure { throw prepareFailure }
    let route = ControlledPreparedRoute(key: request.key, runtime: self)
    handles.append(route)
    return route
  }

  func handle(_ uid: String) -> ControlledPreparedRoute? {
    handles.last { $0.key.deviceUID == uid }
  }

  func emit(_ name: String) {
    occurred.insert(name)
    for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.succeed() }
  }

  func wait(_ name: String) async throws {
    if occurred.contains(name) { return }
    let waiter = ControlledRuntimeWaiter()
    waiters[name, default: []].append(waiter)
    defer {
      waiters[name]?.removeAll { $0 === waiter }
      if waiters[name]?.isEmpty == true { waiters[name] = nil }
    }
    try await awaitWaiter(waiter, waitedFor: name)
  }

  func waitForPreparationStarted(count: Int) async throws {
    if requests.count >= count { return }
    let waiter = ControlledRuntimeWaiter()
    preparationCountWaiters.append((count, waiter))
    defer { preparationCountWaiters.removeAll { $0.waiter === waiter } }
    try await awaitWaiter(waiter, waitedFor: "preparation count \(count)")
  }

  func releasePreparation(_ uid: String) {
    holdPreparation.remove(uid)
    preparationGates.removeValue(forKey: uid)?.resume()
  }

  func suspendUpdate(_ uid: String) async {
    if holdUpdates.contains(uid) { await withCheckedContinuation { updateGates[uid] = $0 } }
  }

  func releaseUpdates(_ uid: String) {
    holdUpdates.remove(uid)
    updateGates.removeValue(forKey: uid)?.resume()
  }

  func suspendOperation(_ operation: ControlDeferredOperation, uid: String) async {
    if holdOperations[uid] == operation {
      emit("deferred-\(operation.rawValue):\(uid)")
      await withCheckedContinuation { operationGates[uid] = $0 }
    }
  }

  func releaseOperation(_ uid: String) {
    holdOperations[uid] = nil
    operationGates.removeValue(forKey: uid)?.resume()
  }

  func waitForRetirementReceipt(_ uid: String) async -> AudioRetirementResult {
    await withCheckedContinuation {
      retirementReceipts[uid] = $0
      emit("retirement-receipt:\(uid)")
    }
  }

  func releaseRetirementReceipt(_ uid: String, result: AudioRetirementResult) {
    holdRetirementReceipt.remove(uid)
    retirementReceipts.removeValue(forKey: uid)?.resume(returning: result)
  }

  func recordCommit() {
    if !retirementReceipts.isEmpty { committedBeforeRetirementReceipt = true }
  }

  func releaseAllHeldGates() {
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
    let receipts = retirementReceipts
    retirementReceipts.removeAll()
    for receipt in receipts.values { receipt.resume(returning: .retired) }
  }

  private func resumePreparationCountWaiters() {
    let remaining = preparationCountWaiters.filter { entry in
      if requests.count >= entry.target {
        entry.waiter.succeed()
        return false
      }
      return true
    }
    preparationCountWaiters = remaining
  }

  private func awaitWaiter(_ waiter: ControlledRuntimeWaiter, waitedFor: String) async throws {
    let timeout = Self.waitTimeout
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
          throw ControlledRuntimeTimeout(waitedFor: waitedFor, timeout: timeout)
        }
        let result = await group.nextResult()
        group.cancelAll()
        while await group.nextResult() != nil {}
        try result?.get()
      }
    } catch {
      releaseAllHeldGates()
      throw error
    }
  }
}

@MainActor
final class ControlledPreparedRoute: PreparedAudioRoute {
  let key: AudioRouteKey
  unowned let runtime: ControlledRoutingRuntime
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)?
  var commits: [AudioOutputState] = []
  var updates: [AudioOutputState] = []
  var nextUpdateReceipt: AudioRouteObservation?
  var levels: [AudioOutputLevels] = []
  var rendering = false
  var ioRunning = false
  var retired = false
  var cancelled = false
  var retirementAttempts = 0
  var retirementError: AudioRouteFailure?
  var cancellationsDuringRetirement = 0
  private var primaryFailure: AudioRouteFailure?

  init(key: AudioRouteKey, runtime: ControlledRoutingRuntime) {
    self.key = key
    self.runtime = runtime
  }

  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation {
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

  func arm() { onObservation?(AudioRouteObservation(key: key, phase: .armed)) }

  func commit(state: AudioOutputState) async throws -> AudioRouteObservation {
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

  func update(state: AudioOutputState) async throws -> AudioRouteObservation {
    updates.append(state)
    runtime.emit("update:\(key.deviceUID):\(updates.count)")
    await runtime.suspendUpdate(key.deviceUID)
    if let receipt = nextUpdateReceipt {
      nextUpdateReceipt = nil
      return receipt
    }
    try checkAdmission()
    return AudioRouteObservation(key: key, phase: .accepted, acceptedRevision: state.revision)
  }

  func requestLevels(_ levels: AudioOutputLevels) { self.levels.append(levels) }

  func cancel() {
    if retirementAttempts > 0 && !retired { cancellationsDuringRetirement += 1 }
    cancelled = true
    rendering = false
  }

  func retire() async -> AudioRetirementResult {
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

  func finishRetirement(
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
}
