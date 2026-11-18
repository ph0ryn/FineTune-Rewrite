import Foundation

/// A controllable external delay; no wall-clock sleep or device operation runs in policy tests.
@MainActor
package final class DevicePolicyTestClock {
  package var now = 0.0
  let requests = AsyncStream<Duration>.makeStream()
  let completions = AsyncStream<Void>.makeStream()
  private var suspended: [CheckedContinuation<Void, Never>] = []

  package init() {}

  package func sleep(_ duration: Duration) async throws {
    try Task.checkCancellation()
    await withCheckedContinuation { continuation in
      suspended.append(continuation)
      requests.continuation.yield(duration)
    }
    completions.continuation.yield(())
  }

  package func advance() {
    let waiting = suspended
    suspended.removeAll()
    for continuation in waiting { continuation.resume() }
  }

  package func finish() {
    advance()
    requests.continuation.finish()
    completions.continuation.finish()
  }

  /// Waits for the next sleep request under a single five-second deadline.
  ///
  /// A missing event or finished stream fails locally; cancellation finishes the stream and drains
  /// the losing wait before returning.
  package func waitForNextRequest() async throws -> Duration {
    try await waitForTestStreamElement(
      of: requests.stream, finishing: requests.continuation, waitedFor: "a sleep request")
  }

  /// Waits for the next sleep completion under the same bounded wait contract.
  package func waitForNextCompletion() async throws {
    _ = try await waitForTestStreamElement(
      of: completions.stream, finishing: completions.continuation, waitedFor: "a sleep completion")
  }
}
