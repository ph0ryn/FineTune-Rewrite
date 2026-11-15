import Dispatch
import FineTuneControl
import FineTuneDomain
import Foundation
import NativeAudio
import Testing

@testable import FineTunePlatform

// The real pool/route lanes and timer run here, but its retire+release operation is injected.
// Fake pointers never reach CoreAudio. C-boundary tests separately exercise actual native release.
@Suite("Explicit native pool cleanup retry")
struct NativeRetirementPoolRetryTests {
  @Test(
    "A new preparation waits for explicit orphan cleanup, including PENDING polls",
    .timeLimit(.minutes(1)))
  @MainActor
  func factoryPreparationJoinsCleanupRetry() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x4000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
      reportCleanup: { script.recordCleanup($0) },
      reportRetired: { script.recordReleased(pointer) })
    try await script.waitForCleanupCount(1, "the first cleanup failure")
    var resolutions = 0
    let runtime = NativeAudioRoutingRuntime(
      resolveApp: { _, _ in
        resolutions += 1
        #expect(script.wasReleased(pointer))
        throw AudioRouteFailure(kind: .unavailable, stage: "resolveProcess", message: "Fixture")
      }, retirementPool: pool, cleanupOwnerID: owner)
    runtime.requestCleanupRetry()
    runtime.requestCleanupRetry()
    let request = AudioRouteRequest(
      key: AudioRouteKey(appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 1),
      processRevision: 1,
      initialState: AudioOutputState(
        revision: 1, effectiveGain: 0.25, isMuted: false, processing: TapInitialState()),
      captureIntent: .userInitiated(sessionID: 7))
    do {
      _ = try await runtime.prepare(request)
      Issue.record("The unavailable fixture app reached native acquisition")
    } catch let failure as AudioRouteFailure {
      #expect(failure.kind == .unavailable)
    }
    #expect(resolutions == 1 && script.calls(pointer) == 3 && script.wasReleased(pointer))
  }

  @Test("Explicit retry services only its factory's failed owners and waits for release")
  func retryIsFactoryScoped() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x1000)))
    let other = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x2000)))
    let owner = UUID()
    let otherOwner = UUID()
    for (pointer, id) in [(first, owner), (other, otherOwner)] {
      script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
      pool.adopt(
        pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: id,
        reportCleanup: { script.recordCleanup($0) },
        reportRetired: { script.recordReleased(pointer) })
    }
    try await script.waitForCleanupCount(2, "both initial cleanup failures")
    #expect(script.calls(first) == 1 && script.calls(other) == 1)
    // An unrelated explicit retry and passive barrier do not rearm these failures.
    await pool.retryFailed(cleanupOwnerID: UUID())
    #expect(script.calls(first) == 1 && script.calls(other) == 1)
    await pool.retryFailed(cleanupOwnerID: owner)
    try await script.waitForRelease(first, "the first factory release")
    #expect(script.calls(first) == 2 && script.wasReleased(first))
    #expect(script.calls(other) == 1 && !script.wasReleased(other))
    await pool.retryFailed(cleanupOwnerID: otherOwner)
    try await script.waitForRelease(other, "the other factory release")
    #expect(script.calls(other) == 2 && script.wasReleased(other))
  }

  @Test(
    "Mixed retry batches settle independently of later foreign adoption", .timeLimit(.minutes(1)))
  @MainActor
  func mixedBatchesDoNotFollowLaterEntries() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x5000)))
    let pending = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x6000)))
    let foreign = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x7000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: first)
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pending)
    for pointer in [first, pending] {
      pool.adopt(
        pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
        reportCleanup: { script.recordCleanup($0) },
        reportRetired: { script.recordReleased(pointer) })
    }
    try await script.waitForCleanupCount(2, "both initial cleanup failures")
    let firstGate = script.holdNext(first)
    let pendingGate = script.holdNext(pending)
    var foreignGate: (entered: EventGate, release: PoolRetirementGate)?
    var batchTasks: [Task<Void, Never>] = []
    // A throwing gate wait must still join the two batch tasks: they own the retry lanes that the
    // release gates below unblock. Cleanup releases every gate first, then drains bounded.
    try await withFailureCleanup(
      operation: {
        let firstBatch = Task {
          await pool.retryFailed(cleanupOwnerID: owner)
          script.completeBatch()
        }
        let secondBatch = Task {
          await pool.retryFailed(cleanupOwnerID: owner)
          script.completeBatch()
        }
        batchTasks = [firstBatch, secondBatch]
        try await firstGate.entered.wait("the first retry entry")
        try await pendingGate.entered.wait("the pending retry entry")
        firstGate.release.signal()
        try await script.waitForReleaseCount(1, "the first retry release")
        #expect(script.releaseOrder == [UInt(bitPattern: first.value)])
        #expect(script.completedBatches == 0 && !script.wasReleased(pending))
        // One selected Entry has gone, but a different factory's new Entry must not become a member.
        script.set([FT_NATIVE_OK], for: foreign)
        let gate = script.holdNext(foreign)
        foreignGate = gate
        pool.adopt(
          foreign, lane: DispatchQueue(label: "fixture.foreign"), cleanupOwnerID: UUID(),
          reportCleanup: { _ in Issue.record("Unexpected foreign cleanup failure") },
          reportRetired: { script.recordReleased(foreign) })
        try await gate.entered.wait("the foreign adoption entry")
        pendingGate.release.signal()
        try await script.waitForReleaseCount(2, "the pending retry release")
        #expect(
          script.releaseOrder == [UInt(bitPattern: first.value), UInt(bitPattern: pending.value)])
        await firstBatch.value
        await secondBatch.value
        #expect(script.completedBatches == 2 && !script.wasReleased(foreign))
        #expect(script.calls(first) == 2 && script.calls(pending) == 3)
        gate.release.signal()
        try await script.waitForReleaseCount(3, "the foreign release")
        #expect(
          script.releaseOrder == [
            UInt(bitPattern: first.value), UInt(bitPattern: pending.value),
            UInt(bitPattern: foreign.value),
          ])
      },
      cleanup: {
        firstGate.release.signal()
        pendingGate.release.signal()
        foreignGate?.release.signal()
        await drainOwnedTasks(batchTasks, waitedFor: "the native retry batch tasks")
      })
  }

  @Test(
    "A throwing retry wait releases and joins both mixed batches", .timeLimit(.minutes(1)))
  @MainActor
  func mixedBatchFailureCleansUpBothBatches() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x8000)))
    let pending = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x9000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: first)
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pending)
    for pointer in [first, pending] {
      pool.adopt(
        pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
        reportCleanup: { script.recordCleanup($0) },
        reportRetired: { script.recordReleased(pointer) })
    }
    try await script.waitForCleanupCount(2, "both initial cleanup failures")
    let firstGate = script.holdNext(first)
    let pendingGate = script.holdNext(pending)
    var batchTasks: [Task<Void, Never>] = []
    do {
      try await withFailureCleanup(
        operation: {
          let firstBatch = Task {
            await pool.retryFailed(cleanupOwnerID: owner)
            script.completeBatch()
          }
          let secondBatch = Task {
            await pool.retryFailed(cleanupOwnerID: owner)
            script.completeBatch()
          }
          batchTasks = [firstBatch, secondBatch]
          try await firstGate.entered.wait("the first retry entry")
          try await pendingGate.entered.wait("the pending retry entry")
          // Observe the first release before throwing; do not infer order from the cleanup signals.
          firstGate.release.signal()
          try await script.waitForReleaseCount(1, "the first retry release")
          #expect(script.releaseOrder == [UInt(bitPattern: first.value)])
          #expect(!script.wasReleased(pending))
          throw MixedBatchFailure()
        },
        cleanup: {
          // Release every held lane before joining either batch, including the already-released
          // first gate, whose release is idempotent.
          firstGate.release.signal()
          pendingGate.release.signal()
          await drainOwnedTasks(batchTasks, waitedFor: "the native retry batch tasks")
        })
      Issue.record("The cleanup path swallowed the fixture failure")
    } catch is MixedBatchFailure {
      // Expected: the cleanup above joined both batches, so the batch assertions remain reachable.
    }
    #expect(script.completedBatches == 2)
    #expect(
      script.releaseOrder == [UInt(bitPattern: first.value), UInt(bitPattern: pending.value)])
    #expect(script.calls(first) == 2 && script.calls(pending) == 3)
    #expect(script.wasReleased(first) && script.wasReleased(pending))
  }

  @Test("An identical repeated failure stays retained for another explicit retry")
  func repeatedFailureDoesNotBecomeSuccess() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x3000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
      reportCleanup: { script.recordCleanup($0) },
      reportRetired: { script.recordReleased(pointer) })
    try await script.waitForCleanupCount(1, "the first cleanup failure")
    #expect(script.cleanupCodes == [-7302])
    await pool.retryFailed(cleanupOwnerID: owner)
    try await script.waitForCleanupCount(2, "the repeated cleanup failure")
    #expect(script.calls(pointer) == 2 && !script.wasReleased(pointer))
    // Both real errors carry the same code; equality must not suppress the second attempt.
    #expect(script.cleanupCodes == [-7302, -7302])
    await pool.retryFailed(cleanupOwnerID: owner)
    try await script.waitForRelease(pointer, "the eventual release")
    #expect(script.calls(pointer) == 3 && script.wasReleased(pointer))
  }
}

/// Thrown only to prove that failure cleanup joined both mixed retry batches before it propagated.
private struct MixedBatchFailure: Error {}

/// A fixture hold released by either the success path or failure cleanup, never twice.
///
/// The same gate is signalled explicitly on the success path and from `withFailureCleanup`; a plain
/// semaphore would release a second waiter if both ran, so release is idempotent.
private final class PoolRetirementGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var released = false

  func signal() {
    lock.lock()
    guard !released else {
      lock.unlock()
      return
    }
    released = true
    lock.unlock()
    semaphore.signal()
  }

  func wait() {
    semaphore.wait()
  }
}

/// A test-owned event gate emitted only by the fake script and its injected callbacks.
///
/// The fake counts events cumulatively, so an event produced before this wait began is still
/// observed. Each wait has one 5-second deadline and throws `TestWaitTimeout` when the event never
/// arrives; a cancelled wait resumes its continuation with `CancellationError` instead.
private final class EventGate: @unchecked Sendable {
  private static let deadline: Duration = .seconds(5)
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
    let ready = waiters.values.filter { $0.target <= count }
    waiters = waiters.filter { $0.value.target > count }
    for waiter in ready { waiter.timeout?.cancel() }
    lock.unlock()
    for waiter in ready { waiter.continuation.resume(returning: ()) }
  }

  func wait(_ description: String, forCount target: Int = 1) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        lock.lock()
        if count >= target {
          lock.unlock()
          continuation.resume(returning: ())
          return
        }
        waiters[id] = Waiter(target: target, continuation: continuation, timeout: nil)
        // Arm the deadline only after this waiter is installed under the lock. A deadline
        // started earlier can fire while installation is stalled, find no waiter, and park here.
        waiters[id]?.timeout = Task { [weak self] in
          do { try await Task.sleep(for: EventGate.deadline) } catch { return }
          self?.finish(id, with: TestWaitTimeout(waitedFor: description))
        }
        // Cancellation may race installation: the handler then finds no waiter, so check here too.
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

  private func finish(_ id: UUID, with error: any Error) {
    lock.lock()
    let waiter = waiters.removeValue(forKey: id)
    waiter?.timeout?.cancel()
    lock.unlock()
    waiter?.continuation.resume(throwing: error)
  }
}

private final class PoolRetirementScript: @unchecked Sendable {
  private let lock = NSLock()
  private let cleanupEvents = EventGate()
  private let releaseEvents = EventGate()
  private var releaseGates: [UInt: EventGate] = [:]
  private var results: [UInt: [FTNativeResult]] = [:]
  private var callCounts: [UInt: Int] = [:]
  private var released: Set<UInt> = []
  private var releaseSequence: [UInt] = []
  private var cleanupSequence: [Int32] = []
  private struct Hold {
    let entered: EventGate
    let release: PoolRetirementGate
  }
  private var holds: [UInt: Hold] = [:]
  private var batchCount = 0

  func holdNext(_ pointer: NativeRoutePointer) -> (
    entered: EventGate, release: PoolRetirementGate
  ) {
    let entered = EventGate()
    let release = PoolRetirementGate()
    lock.lock()
    holds[UInt(bitPattern: pointer.value)] = Hold(entered: entered, release: release)
    lock.unlock()
    return (entered, release)
  }

  func completeBatch() {
    lock.lock()
    batchCount += 1
    lock.unlock()
  }

  var completedBatches: Int {
    lock.lock()
    defer { lock.unlock() }
    return batchCount
  }

  var cleanupCodes: [Int32] {
    lock.lock()
    defer { lock.unlock() }
    return cleanupSequence
  }

  var releaseOrder: [UInt] {
    lock.lock()
    defer { lock.unlock() }
    return releaseSequence
  }

  func waitForCleanupCount(_ count: Int, _ description: String) async throws {
    try await cleanupEvents.wait(description, forCount: count)
  }

  func waitForReleaseCount(_ count: Int, _ description: String) async throws {
    try await releaseEvents.wait(description, forCount: count)
  }

  func waitForRelease(_ pointer: NativeRoutePointer, _ description: String) async throws {
    try await releaseGate(for: UInt(bitPattern: pointer.value)).wait(description)
  }

  private func releaseGate(for key: UInt) -> EventGate {
    lock.lock()
    defer { lock.unlock() }
    if let gate = releaseGates[key] { return gate }
    let gate = EventGate()
    releaseGates[key] = gate
    return gate
  }

  func recordCleanup(_ error: FTNativeError) {
    lock.lock()
    cleanupSequence.append(error.code)
    lock.unlock()
    cleanupEvents.emit()
  }

  func set(_ results: [FTNativeResult], for pointer: NativeRoutePointer) {
    lock.lock()
    defer { lock.unlock() }
    self.results[UInt(bitPattern: pointer.value)] = results
  }

  func perform(_ pointer: NativeRoutePointer) -> NativeRouteResult {
    lock.lock()
    let key = UInt(bitPattern: pointer.value)
    callCounts[key, default: 0] += 1
    let result = results[key]!.removeFirst()
    let hold = holds.removeValue(forKey: key)
    lock.unlock()
    if let hold {
      hold.entered.emit()
      // Only this injected NRT test operation is held, never an audio callback.
      hold.release.wait()
    }
    return NativeRouteResult(
      result: result, snapshot: FTNativeRouteSnapshot(),
      failure: result == FT_NATIVE_FAILED
        ? FTNativeError(kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_DESTROY_IOPROC, code: -7302)
        : FTNativeError())
  }

  func recordReleased(_ pointer: NativeRoutePointer) {
    let key = UInt(bitPattern: pointer.value)
    let gate = releaseGate(for: key)
    lock.lock()
    let inserted = released.insert(key).inserted
    if inserted { releaseSequence.append(key) }
    lock.unlock()
    guard inserted else { return }
    gate.emit()
    releaseEvents.emit()
  }

  func calls(_ pointer: NativeRoutePointer) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return callCounts[UInt(bitPattern: pointer.value), default: 0]
  }

  func wasReleased(_ pointer: NativeRoutePointer) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return released.contains(UInt(bitPattern: pointer.value))
  }
}
