import Dispatch
import FineTuneControl
import FineTuneDomain
import Foundation
import NativeAudio
import Testing

@testable import FineTunePlatform

// The real pool/route lanes run here with a deterministic polling scheduler and injected
// retire+release operation. Fake pointers never reach CoreAudio.
@Suite("Explicit native pool cleanup retry", .timeLimit(.minutes(1)))
struct NativeRetirementPoolRetryTests {
  @Test("A new preparation waits for explicit orphan cleanup, including PENDING polls")
  @MainActor
  func factoryPreparationJoinsCleanupRetry() async throws {
    let scheduler = TestRetirementScheduler()
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(
      retireAndRelease: script.perform, scheduleMonitor: scheduler.monitorScheduler)
    let routeLane = DispatchQueue(label: "fixture.route")
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x4000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: routeLane, cleanupOwnerID: owner,
      reportCleanup: { script.recordCleanup($0) },
      reportRetired: { script.recordReleased(pointer) })
    try await scheduler.step(lanes: [routeLane], scheduleCount: 1)
    #expect(script.cleanupCodes == [-7302] && !script.wasReleased(pointer))

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
    let prepareTask = Task {
      do {
        _ = try await runtime.prepare(request)
        return AudioRouteFailure?.none
      } catch let failure as AudioRouteFailure {
        return failure
      }
    }

    try await scheduler.step(lanes: [routeLane], scheduleCount: 2)
    #expect(resolutions == 0 && script.calls(pointer) == 2 && !script.wasReleased(pointer))

    try await scheduler.step(lanes: [routeLane])
    let failure = try await withTimeout(waitedFor: "prepare after cleanup retry") {
      try await prepareTask.value
    }
    #expect(failure?.kind == .unavailable)
    #expect(resolutions == 1 && script.calls(pointer) == 3 && script.wasReleased(pointer))
  }

  @Test("Explicit retry services only its factory's failed owners and waits for release")
  func retryIsFactoryScoped() async throws {
    let scheduler = TestRetirementScheduler()
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(
      retireAndRelease: script.perform, scheduleMonitor: scheduler.monitorScheduler)
    let routeLane = DispatchQueue(label: "fixture.route")
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x1000)))
    let other = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x2000)))
    let owner = UUID()
    let otherOwner = UUID()
    for (pointer, id) in [(first, owner), (other, otherOwner)] {
      script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
      pool.adopt(
        pointer, lane: routeLane, cleanupOwnerID: id,
        reportCleanup: { script.recordCleanup($0) },
        reportRetired: { script.recordReleased(pointer) })
    }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 1)
    #expect(script.calls(first) == 1 && script.calls(other) == 1)

    // An unrelated explicit retry does not rearm these failures.
    await pool.retryFailed(cleanupOwnerID: UUID())
    #expect(script.calls(first) == 1 && script.calls(other) == 1)

    let firstRetry = Task { await pool.retryFailed(cleanupOwnerID: owner) }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 2)
    try await withTimeout(waitedFor: "first factory retry") { await firstRetry.value }
    #expect(script.calls(first) == 2 && script.wasReleased(first))
    #expect(script.calls(other) == 1 && !script.wasReleased(other))

    let otherRetry = Task { await pool.retryFailed(cleanupOwnerID: otherOwner) }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 3)
    try await withTimeout(waitedFor: "other factory retry") { await otherRetry.value }
    #expect(script.calls(other) == 2 && script.wasReleased(other))
  }

  @Test("Mixed retry batches settle independently of later foreign adoption")
  func mixedBatchesDoNotFollowLaterEntries() async throws {
    let scheduler = TestRetirementScheduler()
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(
      retireAndRelease: script.perform, scheduleMonitor: scheduler.monitorScheduler)
    let routeLane = DispatchQueue(label: "fixture.route")
    let foreignLane = DispatchQueue(label: "fixture.foreign")
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x5000)))
    let pending = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x6000)))
    let foreign = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x7000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: first)
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pending)
    for pointer in [first, pending] {
      pool.adopt(
        pointer, lane: routeLane, cleanupOwnerID: owner,
        reportCleanup: { script.recordCleanup($0) },
        reportRetired: { script.recordReleased(pointer) })
    }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 1)
    #expect(script.cleanupCodes.count == 2)

    let firstBatch = Task {
      await pool.retryFailed(cleanupOwnerID: owner)
      script.completeBatch()
    }
    let secondBatch = Task {
      await pool.retryFailed(cleanupOwnerID: owner)
      script.completeBatch()
    }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 2)
    #expect(script.releaseOrder == [UInt(bitPattern: first.value)])
    #expect(script.completedBatches == 0 && !script.wasReleased(pending))

    // A different factory's new entry adopted mid-retry must not block or join the active batches.
    script.set([FT_NATIVE_PENDING, FT_NATIVE_OK], for: foreign)
    pool.adopt(
      foreign, lane: foreignLane, cleanupOwnerID: UUID(),
      reportCleanup: { _ in Issue.record("Unexpected foreign cleanup failure") },
      reportRetired: { script.recordReleased(foreign) })
    try await scheduler.step(lanes: [routeLane, foreignLane])
    try await withTimeout(waitedFor: "mixed retry batches") {
      await firstBatch.value
      await secondBatch.value
    }
    #expect(script.completedBatches == 2 && !script.wasReleased(foreign))
    #expect(
      script.releaseOrder == [UInt(bitPattern: first.value), UInt(bitPattern: pending.value)])
    #expect(script.calls(first) == 2 && script.calls(pending) == 3)

    try await scheduler.step(lanes: [foreignLane])
    #expect(
      script.releaseOrder == [
        UInt(bitPattern: first.value), UInt(bitPattern: pending.value),
        UInt(bitPattern: foreign.value),
      ])
  }

  @Test("An identical repeated failure stays retained for another explicit retry")
  func repeatedFailureDoesNotBecomeSuccess() async throws {
    let scheduler = TestRetirementScheduler()
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(
      retireAndRelease: script.perform, scheduleMonitor: scheduler.monitorScheduler)
    let routeLane = DispatchQueue(label: "fixture.route")
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x3000)))
    let owner = UUID()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: routeLane, cleanupOwnerID: owner,
      reportCleanup: { script.recordCleanup($0) },
      reportRetired: { script.recordReleased(pointer) })
    try await scheduler.step(lanes: [routeLane], scheduleCount: 1)
    #expect(script.cleanupCodes == [-7302])

    let secondAttempt = Task { await pool.retryFailed(cleanupOwnerID: owner) }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 2)
    try await withTimeout(waitedFor: "repeated cleanup failure") { await secondAttempt.value }
    #expect(script.calls(pointer) == 2 && !script.wasReleased(pointer))
    // Both real errors carry the same code; equality must not suppress the second attempt.
    #expect(script.cleanupCodes == [-7302, -7302])

    let thirdAttempt = Task { await pool.retryFailed(cleanupOwnerID: owner) }
    try await scheduler.step(lanes: [routeLane], scheduleCount: 3)
    try await withTimeout(waitedFor: "eventual release") { await thirdAttempt.value }
    #expect(script.calls(pointer) == 3 && script.wasReleased(pointer))
  }
}

private final class TestRetirementScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var activeLane: DispatchQueue?
  private var activeTick: (@Sendable () -> Void)?
  private let scheduledSignal = CountSignal()

  var monitorScheduler: NativeRetirementPool.MonitorScheduler {
    { [weak self] queue, onTick in
      guard let self else { return {} }
      self.lock.lock()
      self.activeLane = queue
      self.activeTick = onTick
      self.lock.unlock()
      self.scheduledSignal.emit()
      return { [weak self] in
        guard let self else { return }
        self.lock.lock()
        self.activeTick = nil
        self.lock.unlock()
      }
    }
  }

  func step(lanes: [DispatchQueue], scheduleCount target: Int? = nil) async throws {
    if let target {
      try await scheduledSignal.wait(forCount: target, waitedFor: "retirement monitor schedule")
    }
    let (queue, tick) = lock.withLock { (activeLane, activeTick) }
    guard let queue, let tick else {
      Issue.record("Expected an active retirement monitor before stepping")
      return
    }
    await drain(queue) { tick() }
    for routeLane in lanes { await drain(routeLane) }
    await drain(queue)
  }

  private func drain(_ queue: DispatchQueue, work: (@Sendable () -> Void)? = nil) async {
    await withCheckedContinuation { continuation in
      queue.async {
        work?()
        continuation.resume()
      }
    }
  }
}

private final class PoolRetirementScript: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [UInt: [FTNativeResult]] = [:]
  private var callCounts: [UInt: Int] = [:]
  private var released: Set<UInt> = []
  private var releaseSequence: [UInt] = []
  private var cleanupSequence: [Int32] = []
  private var batchCount = 0

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

  func recordCleanup(_ error: FTNativeError) {
    lock.lock()
    cleanupSequence.append(error.code)
    lock.unlock()
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
    lock.unlock()
    return NativeRouteResult(
      result: result, snapshot: FTNativeRouteSnapshot(),
      failure: result == FT_NATIVE_FAILED
        ? FTNativeError(kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_DESTROY_IOPROC, code: -7302)
        : FTNativeError())
  }

  func recordReleased(_ pointer: NativeRoutePointer) {
    let key = UInt(bitPattern: pointer.value)
    lock.lock()
    let inserted = released.insert(key).inserted
    if inserted { releaseSequence.append(key) }
    lock.unlock()
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
