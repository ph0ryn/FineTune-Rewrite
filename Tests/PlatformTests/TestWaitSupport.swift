import Testing

/// A bounded wait that failed because the expected state never arrived.
struct TestWaitTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  var description: String { "Timed out waiting for \(waitedFor)" }
}

/// A bounded wait for an owned task that missed its deadline.
struct TestTaskWaitTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  /// Whether the task finished after the deadline path cancelled and released it.
  let finishedAfterRelease: Bool

  var description: String {
    let drained = finishedAfterRelease ? "finished" : "is still pending"
    return "Timed out waiting for \(waitedFor); the task \(drained) after release"
  }
}

private struct TestWaitStreamFinished: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  var description: String { "Event stream ended while waiting for \(waitedFor)" }
}

/// Waits for the first matching stream value, one deadline, then drains the cancelled loser.
func waitForStreamValue<Element: Sendable>(
  in stream: AsyncStream<Element>,
  finishing continuation: AsyncStream<Element>.Continuation,
  waitedFor: String,
  timeout: Duration = .seconds(5),
  matches: @escaping @Sendable (Element) -> Bool
) async throws -> Element {
  try Task.checkCancellation()
  return try await withTaskCancellationHandler {
    try await withThrowingTaskGroup(of: Element.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        while let element = await iterator.next() {
          if matches(element) { return element }
        }
        throw TestWaitStreamFinished(waitedFor: waitedFor)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw TestWaitTimeout(waitedFor: waitedFor)
      }
      let first = await group.nextResult()
      if case .failure? = first { continuation.finish() }
      group.cancelAll()
      while await group.nextResult() != nil {}
      try Task.checkCancellation()
      guard let first else { throw TestWaitStreamFinished(waitedFor: waitedFor) }
      return try first.get()
    }
  } onCancel: {
    continuation.finish()
  }
}

/// Runs async test work and awaits cleanup only when the test body throws or is cancelled.
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

/// Awaits an owned non-throwing task with one cooperative deadline.
///
/// Awaiting `Task.value` is not cancellable, so the wait is driven by a completion event instead:
/// the watcher is deliberately unstructured and is never joined by the deadline path. On timeout or
/// caller cancellation this cancels the task, runs `release` to resume any clock or continuation it
/// is parked on, and drains completion under a second deadline before throwing. A task that finishes
/// only because of that release is still reported as a missed deadline; it never silently passes.
///
/// `release` must itself be a finite release action (cancel a clock, resume a test gate) and must
/// not await the owned task; anything it waits on is outside `releaseTimeout` and can reintroduce
/// the unbounded wait this helper exists to avoid. If the post-release drain misses its deadline,
/// the task and its unstructured watcher can outlive this wait, so the diagnostic says the task is
/// still pending rather than claiming everything was drained.
@MainActor
func waitForOwnedTask(
  _ task: Task<Void, Never>,
  waitedFor: String,
  timeout: Duration = .seconds(5),
  releaseTimeout: Duration = .seconds(1),
  releasing release: @MainActor () async -> Void = {}
) async throws {
  let (completions, completionEvents) = AsyncStream<Void>.makeStream()
  let (drains, drainEvents) = AsyncStream<Void>.makeStream()
  // Intentionally unstructured and nonisolated: `Task.value` cannot be cancelled, so joining it
  // would reintroduce the unbounded wait; completion must not queue behind main-actor work.
  _ = Task.detached(priority: Task.currentPriority) {
    await task.value
    completionEvents.yield()
    completionEvents.finish()
    drainEvents.yield()
    drainEvents.finish()
  }
  do {
    _ = try await waitForStreamValue(
      in: completions, finishing: completionEvents, waitedFor: waitedFor, timeout: timeout,
      matches: { _ in true })
  } catch {
    let cancelled = error is CancellationError || Task.isCancelled
    task.cancel()
    await release()
    // A cancelled caller cannot enter `waitForStreamValue` again (it checks cancellation first), so
    // the drain runs unstructured with its own deadline: bounded, and not skipped on cancellation.
    let finishedAfterRelease = await Task { @MainActor in
      do {
        _ = try await waitForStreamValue(
          in: drains, finishing: drainEvents, waitedFor: "the release of \(waitedFor)",
          timeout: releaseTimeout, matches: { _ in true })
        return true
      } catch {
        return false
      }
    }.value
    if cancelled {
      if !finishedAfterRelease {
        // Cancellation must not hide a target that missed its release deadline: report it before
        // preserving the caller's cancellation semantics.
        Issue.record(
          "Timed out waiting for \(waitedFor); the owned task is still pending after release"
        )
      }
      throw CancellationError()
    }
    if error is TestWaitTimeout {
      throw TestTaskWaitTimeout(
        waitedFor: waitedFor, finishedAfterRelease: finishedAfterRelease)
    }
    throw error
  }
}

/// Drains owned tasks whose clocks, continuations and cancellation were already released.
///
/// Failure cleanup must report a still-pending task instead of parking the suite, so each drain has
/// its own deadline and records a test issue rather than awaiting `Task.value` without a bound.
@MainActor
func drainOwnedTasks(_ tasks: [Task<Void, Never>], waitedFor: String) async {
  for task in tasks {
    do {
      try await waitForOwnedTask(task, waitedFor: waitedFor, timeout: .seconds(1))
    } catch {
      Issue.record("\(error)")
    }
  }
}
