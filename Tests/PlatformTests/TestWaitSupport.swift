import Foundation
import Testing

/// Bounded wait failure when an expected test event or task completion does not arrive in time.
struct TestWaitTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  var description: String { "Timed out waiting for \(waitedFor)" }
}

/// Runs an async operation under a single bounded timeout, cancelling the loser before returning.
func withTimeout<T: Sendable>(
  _ timeout: Duration = .seconds(5),
  waitedFor: String,
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  try Task.checkCancellation()
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw TestWaitTimeout(waitedFor: waitedFor)
    }
    let first = try await group.next()!
    group.cancelAll()
    return first
  }
}

/// Runs a MainActor operation under one bounded timeout, invoking `onTimeout` to unblock owned
/// work if the deadline expires before `withThrowingTaskGroup` drains.
@MainActor
func withMainActorTimeout<T: Sendable>(
  _ timeout: Duration = .seconds(5),
  waitedFor: String,
  onTimeout: (@MainActor () async -> Void)? = nil,
  operation: @MainActor @Sendable @escaping () async throws -> T
) async throws -> T {
  try Task.checkCancellation()
  return try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw TestWaitTimeout(waitedFor: waitedFor)
    }
    do {
      let first = try await group.next()!
      group.cancelAll()
      return first
    } catch {
      group.cancelAll()
      await onTimeout?()
      throw error
    }
  }
}

/// Runs MainActor test work and runs `cleanup` only if the operation throws or is cancelled.
@MainActor
func withFailureCleanup<Value>(
  operation: @MainActor () async throws -> Value,
  cleanup: @MainActor () async -> Void
) async throws -> Value {
  do {
    return try await operation()
  } catch {
    await cleanup()
    throw error
  }
}

/// Observes a property mutation triggered by `trigger` under one bounded timeout.
@MainActor
func awaitObservationChange(
  waitedFor: String,
  timeout: Duration = .seconds(5),
  observing: () -> Void,
  trigger: () async throws -> Void
) async throws {
  let changed = CountSignal()
  withObservationTracking {
    observing()
  } onChange: {
    changed.emit()
  }
  try await trigger()
  try await changed.wait(forCount: 1, waitedFor: waitedFor, timeout: timeout)
}

/// Thread-safe cumulative event counter with bounded async waiting.
/// Synchronous `emit()` works from both actors and DispatchQueue callbacks.
final class CountSignal: @unchecked Sendable {
  private struct Waiter {
    let target: Int
    let continuation: CheckedContinuation<Void, any Error>
    var timeout: Task<Void, Never>?
  }

  private let lock = NSLock()
  private var count = 0
  private var waiters: [UUID: Waiter] = [:]

  func emit() {
    lock.lock()
    count += 1
    let ready = waiters.filter { $0.value.target <= count }
    for id in ready.keys { waiters.removeValue(forKey: id) }
    for waiter in ready.values { waiter.timeout?.cancel() }
    lock.unlock()
    for waiter in ready.values { waiter.continuation.resume() }
  }

  func wait(
    forCount target: Int = 1,
    waitedFor: String,
    timeout: Duration = .seconds(5)
  ) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        lock.lock()
        if count >= target {
          lock.unlock()
          continuation.resume()
          return
        }
        waiters[id] = Waiter(target: target, continuation: continuation, timeout: nil)
        waiters[id]?.timeout = Task { [weak self] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(id, with: TestWaitTimeout(waitedFor: waitedFor))
        }
        if Task.isCancelled {
          waiters.removeValue(forKey: id)?.timeout?.cancel()
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        lock.unlock()
      }
    } onCancel: {
      finish(id, with: CancellationError())
    }
  }

  func cancelAll() {
    lock.lock()
    let pending = Array(waiters.values)
    waiters.removeAll()
    for waiter in pending { waiter.timeout?.cancel() }
    lock.unlock()
    for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
  }

  private func finish(_ id: UUID, with error: any Error) {
    lock.lock()
    let waiter = waiters.removeValue(forKey: id)
    waiter?.timeout?.cancel()
    lock.unlock()
    waiter?.continuation.resume(throwing: error)
  }
}

/// Deterministic virtual clock shared by platform backend and persistence suites.
/// Sleepers ready at the same deadline resume in registration order.
actor ManualTestClock {
  private struct Sleeper {
    let deadline: Duration
    let sequence: Int
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var now = Duration.zero
  private var sleepers: [UUID: Sleeper] = [:]
  private var nextSequence = 0
  private let sleepSignal = CountSignal()

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        sleepers[id] = Sleeper(
          deadline: now + duration, sequence: nextSequence, continuation: continuation)
        nextSequence += 1
        sleepSignal.emit()
      }
    } onCancel: {
      Task { await self.cancelSleeper(id) }
    }
  }

  func waitForSleepCount(_ count: Int, timeout: Duration = .seconds(5)) async throws {
    try await sleepSignal.wait(
      forCount: count, waitedFor: "\(count) injected clock sleep(s)", timeout: timeout)
  }

  func advance(by duration: Duration) {
    now += duration
    let ready = sleepers.filter { $0.value.deadline <= now }.sorted {
      ($0.value.deadline, $0.value.sequence) < ($1.value.deadline, $1.value.sequence)
    }
    for (id, sleeper) in ready {
      sleepers.removeValue(forKey: id)
      sleeper.continuation.resume()
    }
  }

  func cancelAllSleeps() {
    let pending = Array(sleepers.values)
    sleepers.removeAll()
    for sleeper in pending { sleeper.continuation.resume(throwing: CancellationError()) }
  }

  private func cancelSleeper(_ id: UUID) {
    sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}
