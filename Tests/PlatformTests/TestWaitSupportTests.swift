import Foundation
import Testing

// Exercises the bounded owned-task wait through the shared manual clock and task completion.
// The failure control uses a 100ms advance against a 101ms deadline, the reviewed shortfall.
@Suite("Bounded owned-task completion", .timeLimit(.minutes(1)))
@MainActor
struct TestWaitSupportTests {
  private actor CompletionProbe {
    private(set) var finished = false

    func markFinished() {
      finished = true
    }
  }

  @MainActor
  private final class MainActorTaskFlags {
    var clockReleased = false
    var parked = false
    var finished = false
    var waiterDone = false
  }

  // A checked continuation that ignores task cancellation, so only the test can unpark its waiter.
  private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
      await withCheckedContinuation { continuation in
        lock.lock()
        guard !opened else {
          lock.unlock()
          continuation.resume()
          return
        }
        self.continuation = continuation
        lock.unlock()
      }
    }

    func open() {
      lock.lock()
      guard !opened else {
        lock.unlock()
        return
      }
      opened = true
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume()
    }
  }

  @Test("A finished owned task completes without release or a timeout")
  func finishedTaskCompletes() async throws {
    let probe = CompletionProbe()
    let task = Task { await probe.markFinished() }
    await task.value  // finished before the 1 s observation budget starts
    try await waitForOwnedTask(
      task, waitedFor: "the finished fixture task", timeout: .seconds(1))
    #expect(await probe.finished)
  }

  @Test("A manual-clock shortfall is a bounded failure that releases and drains the task")
  func manualClockShortfallIsBounded() async throws {
    let clock = DeviceBackendTestClock()
    let probe = CompletionProbe()
    let task = Task {
      do {
        try await clock.sleep(for: .milliseconds(101))
      } catch {
        // The release path cancels the sleep exactly as the production cancellation path does.
      }
      await probe.markFinished()
    }
    try await clock.waitForSleepCount(1)
    await clock.advance(by: .milliseconds(100))
    // Failure control: the 100ms advance never reaches the 101ms deadline, so the task stays parked
    // exactly where the reviewed regression leaves it. Awaiting `task.value` here would not return.
    #expect(await probe.finished == false)

    var releaseCount = 0
    let started = ContinuousClock.now
    do {
      try await waitForOwnedTask(
        task, waitedFor: "the parked fixture task", timeout: .milliseconds(100),
        releasing: {
          releaseCount += 1
          await clock.cancelAllSleeps()
        })
      Issue.record("A parked task was reported as complete")
    } catch let failure as TestTaskWaitTimeout {
      #expect(failure.waitedFor == "the parked fixture task")
      #expect(failure.finishedAfterRelease)
    }
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(releaseCount == 1)
    #expect(await probe.finished)
  }

  @Test("A cancelled wait reports a target its bounded release drain did not finish")
  func cancellationReportsUnfinishedDrain() async throws {
    let clock = DeviceBackendTestClock()
    let flags = MainActorTaskFlags()
    let gate = ContinuationGate()
    let (parked, parkedEvents) = AsyncStream<Void>.makeStream()
    var target: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        let owned = Task { @MainActor in
          do {
            try await clock.sleep(for: .seconds(30))
          } catch {
            // The release callback below cancels this sleep; the target then parks on `gate`.
            flags.clockReleased = true
          }
          flags.parked = true
          parkedEvents.yield()
          await gate.wait()
          flags.finished = true
        }
        target = owned
        try await clock.waitForSleepCount(1)
        try await withKnownIssue(
          "A cancelled wait must report an owned task that outlived its release drain",
          {
            // The waiter is created inside `withKnownIssue` so its recorded issue joins this
            // known-issue scope. `gate` is deliberately absent from the release callback.
            let waiter = Task { @MainActor in
              try await waitForOwnedTask(
                owned, waitedFor: "the cancelled fixture task", timeout: .seconds(5),
                releaseTimeout: .milliseconds(100),
                releasing: { await clock.cancelAllSleeps() })
            }
            waiter.cancel()
            do {
              try await waiter.value
              Issue.record("The cancelled wait returned without CancellationError")
            } catch is CancellationError {
              // Expected: caller cancellation is preserved even when the drain missed.
            }
            _ = try await waitForStreamValue(
              in: parked, finishing: parkedEvents, waitedFor: "the parked fixture task",
              matches: { _ in true })
            #expect(
              flags.finished == false,
              "The target must stay unfinished until the extra gate is opened")
          },
          matching: { issue in
            issue.comments.contains { $0.description.contains("still pending") }
          })
        // A matched known issue does not throw, so the normal path also has to finish the fixture.
        gate.open()
        if let target {
          await drainOwnedTasks([target], waitedFor: "the cancelled fixture task")
        }
      },
      cleanup: {
        gate.open()
        if let target {
          await drainOwnedTasks([target], waitedFor: "the cancelled fixture task")
        }
      })
    #expect(flags.clockReleased && flags.parked && flags.finished)
  }

  @Test("Cancelling the waiter still releases the clock and drains the owned task")
  func cancellationReleasesAndDrains() async throws {
    let clock = DeviceBackendTestClock()
    let flags = MainActorTaskFlags()
    let gate = ContinuationGate()
    let (parked, parkedEvents) = AsyncStream<Void>.makeStream()
    let (targetDone, targetDoneEvents) = AsyncStream<Void>.makeStream()
    let (waiterDone, waiterDoneEvents) = AsyncStream<Void>.makeStream()
    var target: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        let owned = Task { @MainActor in
          do {
            try await clock.sleep(for: .seconds(30))
          } catch {
            // The release callback below cancels this sleep and the target then parks on `gate`.
            flags.clockReleased = true
          }
          flags.parked = true
          parkedEvents.yield()
          await gate.wait()
          flags.finished = true
          targetDoneEvents.yield()
        }
        target = owned
        try await clock.waitForSleepCount(1)
        // The waiter is cancelled immediately, before it can install its completion event wait;
        // the post-release gate below, not stream installation, is what proves the drain.
        let waiter = Task { @MainActor in
          defer {
            flags.waiterDone = true
            waiterDoneEvents.yield()
          }
          try await waitForOwnedTask(
            owned, waitedFor: "the cancelled fixture task",
            releasing: { await clock.cancelAllSleeps() })
        }
        waiter.cancel()
        _ = try await waitForStreamValue(
          in: parked, finishing: parkedEvents, waitedFor: "the parked fixture task",
          matches: { _ in true })
        #expect(flags.parked && flags.finished == false)
        // Bounded absence of the waiter-done event while the gate holds its target is the
        // synchronization oracle; it is not an arbitrary settle delay. The waiter itself writes
        // the flag and event, so removing the drain cannot hide behind a late observer task.
        do {
          _ = try await waitForStreamValue(
            in: waiterDone, finishing: waiterDoneEvents, waitedFor: "the waiter completion",
            timeout: .milliseconds(100), matches: { _ in true })
          Issue.record("The waiter finished while the post-release gate was held")
        } catch is TestWaitTimeout {
          // Expected: the waiter cannot finish until the target is released.
          #expect(flags.waiterDone == false)
        }
        gate.open()
        _ = try await waitForStreamValue(
          in: targetDone, finishing: targetDoneEvents, waitedFor: "the released fixture task",
          matches: { _ in true })
        do {
          try await waiter.value
          Issue.record("The cancelled wait returned without CancellationError")
        } catch is CancellationError {
          #expect(flags.waiterDone)
          #expect(flags.finished, "The target must finish before the waiter reports cancellation")
        }
      },
      cleanup: {
        gate.open()
        if let target {
          await drainOwnedTasks([target], waitedFor: "the cancelled fixture task")
        }
      })
    #expect(flags.clockReleased && flags.parked && flags.finished && flags.waiterDone)
  }

  @Test("A missed post-release drain stays bounded and is reported as still pending")
  func unfinishedReleaseDrainIsReported() async throws {
    let flags = MainActorTaskFlags()
    let gate = ContinuationGate()
    let (parked, parkedEvents) = AsyncStream<Void>.makeStream()
    var target: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        let owned = Task { @MainActor in
          flags.parked = true
          parkedEvents.yield()
          await gate.wait()
          flags.finished = true
        }
        target = owned
        _ = try await waitForStreamValue(
          in: parked, finishing: parkedEvents, waitedFor: "the parked fixture task",
          matches: { _ in true })
        do {
          try await waitForOwnedTask(
            owned, waitedFor: "the still-parked fixture task",
            timeout: .milliseconds(100), releaseTimeout: .milliseconds(100))
          Issue.record("A still-parked task was reported as complete")
        } catch let failure as TestTaskWaitTimeout {
          #expect(failure.waitedFor == "the still-parked fixture task")
          #expect(failure.finishedAfterRelease == false)
        }
        let started = ContinuousClock.now
        await withKnownIssue(
          "The bounded drain must report an owned task that is still pending",
          {
            await drainOwnedTasks([owned], waitedFor: "the still-parked fixture task")
            // The two default drain deadlines take about two seconds; this is only a coarse bound.
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(flags.finished == false)
          },
          matching: { issue in
            issue.comments.contains { $0.description.contains("still pending") }
          })
        gate.open()
        if let target {
          await drainOwnedTasks([target], waitedFor: "the released fixture task")
        }
      },
      cleanup: {
        gate.open()
        if let target {
          await drainOwnedTasks([target], waitedFor: "the released fixture task")
        }
      })
    #expect(flags.parked && flags.finished)
  }
}
