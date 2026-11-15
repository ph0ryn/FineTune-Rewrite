import AppTestSupport
import Foundation
import Testing

/// Additive controls for the shared bounded wait; these do not restate the moved policy oracles.
@Suite("Bounded async support helpers")
@MainActor
struct AppTestSupportTests {
  @Test(
    "An empty stream times out at the caller's deadline and the drained stream then reports its end"
  )
  func emptyStreamTimesOutAndReportsItsDrainedEnd() async throws {
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    let timeout: Duration = .milliseconds(50)
    let timeoutMessage: String
    do {
      _ = try await waitForTestStreamElement(
        of: stream, finishing: continuation, waitedFor: "an empty support probe", timeout: timeout)
      Issue.record("An empty stream must not deliver an element")
      return
    } catch {
      timeoutMessage = String(describing: error)
    }
    #expect(timeoutMessage.contains("Timed out after"))
    #expect(timeoutMessage.contains("waiting for an empty support probe"))

    let endedMessage: String
    do {
      _ = try await waitForTestStreamElement(
        of: stream, finishing: continuation, waitedFor: "the drained probe", timeout: timeout)
      Issue.record("A finished stream must not deliver an element")
      return
    } catch {
      endedMessage = String(describing: error)
    }
    #expect(endedMessage.contains("Event stream ended while waiting for"))
    #expect(endedMessage.contains("the drained probe"))
  }
}
