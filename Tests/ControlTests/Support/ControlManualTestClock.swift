import Foundation

private struct ControlClockWaitTimeout: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  let timeout: Duration
  var description: String { "Timed out after \(timeout) waiting for \(waitedFor)" }
}

private struct ControlClockStreamFinished: Error, CustomStringConvertible, Sendable {
  let waitedFor: String
  var description: String { "Clock stream ended while waiting for \(waitedFor)" }
}

/// Deterministic clock for Control policy tests; no wall-clock sleeps or OS timers.
@MainActor
final class ControlManualTestClock {
  var now = 0.0
  private let requests = AsyncStream<Duration>.makeStream()
  private let completions = AsyncStream<Void>.makeStream()
  private var suspended: [CheckedContinuation<Void, Never>] = []

  func sleep(_ duration: Duration) async throws {
    try Task.checkCancellation()
    await withCheckedContinuation { continuation in
      suspended.append(continuation)
      requests.continuation.yield(duration)
    }
    completions.continuation.yield(())
  }

  func advance() {
    let waiting = suspended
    suspended.removeAll()
    for continuation in waiting { continuation.resume() }
  }

  func finish() {
    advance()
    requests.continuation.finish()
    completions.continuation.finish()
  }

  func waitForNextRequest() async throws -> Duration {
    try await waitNext(
      of: requests.stream, finishing: requests.continuation, waitedFor: "sleep request")
  }

  func waitForNextCompletion() async throws {
    _ = try await waitNext(
      of: completions.stream, finishing: completions.continuation, waitedFor: "sleep completion")
  }

  private func waitNext<Element: Sendable>(
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
            throw ControlClockStreamFinished(waitedFor: waitedFor)
          }
          return element
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw ControlClockWaitTimeout(waitedFor: waitedFor, timeout: timeout)
        }
        let first = await group.nextResult()
        if case .failure? = first { continuation.finish() }
        group.cancelAll()
        while await group.nextResult() != nil {}
        try Task.checkCancellation()
        guard let first else { throw ControlClockStreamFinished(waitedFor: waitedFor) }
        return try first.get()
      }
    } onCancel: {
      continuation.finish()
    }
  }
}
