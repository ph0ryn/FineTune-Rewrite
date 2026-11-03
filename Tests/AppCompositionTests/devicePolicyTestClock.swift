import Foundation

/// A controllable external delay; no wall-clock sleep or device operation runs in policy tests.
@MainActor
final class DevicePolicyTestClock {
  var now = 0.0
  let requests = AsyncStream<Duration>.makeStream()
  let completions = AsyncStream<Void>.makeStream()
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
}
