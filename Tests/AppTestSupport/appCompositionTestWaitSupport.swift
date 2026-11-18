import Foundation

private struct AppCompositionTestWaitTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  let timeout: Duration
  var description: String { "Timed out after \(timeout) waiting for \(waitedFor)" }
}

private struct AppCompositionTestWaitStreamFinished: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  var description: String { "Event stream ended while waiting for \(waitedFor)" }
}

/// Waits for one stream element with a local deadline and finishes the stream on failure/cancel.
package func waitForTestStreamElement<Element: Sendable>(
  of stream: AsyncStream<Element>,
  finishing continuation: AsyncStream<Element>.Continuation,
  waitedFor: String,
  timeout: Duration = .seconds(5)
) async throws -> Element {
  try Task.checkCancellation()
  return try await withTaskCancellationHandler {
    try await withThrowingTaskGroup(of: Element.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        guard let element = await iterator.next() else {
          throw AppCompositionTestWaitStreamFinished(waitedFor: waitedFor)
        }
        return element
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AppCompositionTestWaitTimeout(waitedFor: waitedFor, timeout: timeout)
      }
      let first = await group.nextResult()
      if case .failure? = first { continuation.finish() }
      group.cancelAll()
      while await group.nextResult() != nil {}
      try Task.checkCancellation()
      guard let first else {
        throw AppCompositionTestWaitStreamFinished(waitedFor: waitedFor)
      }
      return try first.get()
    }
  } onCancel: {
    continuation.finish()
  }
}

/// Awaits cleanup on both normal return and thrown/cancelled test-body exits.
@MainActor
package func withAsyncTestCleanup<Value>(
  operation: @MainActor () async throws -> Value,
  cleanup: @MainActor () async -> Void
) async throws -> Value {
  do {
    let value = try await operation()
    await cleanup()
    return value
  } catch {
    await cleanup()
    throw error
  }
}
