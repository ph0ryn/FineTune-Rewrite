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
  @Test("A new preparation waits for explicit orphan cleanup, including PENDING polls")
  @MainActor
  func factoryPreparationJoinsCleanupRetry() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x4000)))
    let owner = UUID()
    let failures = AsyncStream<Void>.makeStream()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
      reportCleanup: { _ in failures.continuation.yield(()) },
      reportRetired: { script.recordReleased(pointer) })
    var iterator = failures.stream.makeAsyncIterator()
    _ = await iterator.next()
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
    failures.continuation.finish()
  }

  @Test("Explicit retry services only its factory's failed owners and waits for release")
  func retryIsFactoryScoped() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x1000)))
    let other = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x2000)))
    let owner = UUID()
    let otherOwner = UUID()
    let failures = AsyncStream<UInt>.makeStream()
    for (pointer, id) in [(first, owner), (other, otherOwner)] {
      script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
      pool.adopt(
        pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: id,
        reportCleanup: { _ in failures.continuation.yield(UInt(bitPattern: pointer.value)) },
        reportRetired: { script.recordReleased(pointer) })
    }
    var iterator = failures.stream.makeAsyncIterator()
    _ = await iterator.next()
    _ = await iterator.next()
    #expect(script.calls(first) == 1 && script.calls(other) == 1)
    // An unrelated explicit retry and passive barrier do not rearm these failures.
    await pool.retryFailed(cleanupOwnerID: UUID())
    #expect(script.calls(first) == 1 && script.calls(other) == 1)
    await pool.retryFailed(cleanupOwnerID: owner)
    #expect(script.calls(first) == 2 && script.wasReleased(first))
    #expect(script.calls(other) == 1 && !script.wasReleased(other))
    await pool.retryFailed(cleanupOwnerID: otherOwner)
    #expect(script.calls(other) == 2 && script.wasReleased(other))
    failures.continuation.finish()
  }

  @Test(
    "Mixed retry batches settle independently of later foreign adoption", .timeLimit(.minutes(1)))
  func mixedBatchesDoNotFollowLaterEntries() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let first = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x5000)))
    let pending = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x6000)))
    let foreign = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x7000)))
    let owner = UUID()
    let failures = AsyncStream<Void>.makeStream()
    let releases = AsyncStream<UInt>.makeStream()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_OK], for: first)
    script.set([FT_NATIVE_FAILED, FT_NATIVE_PENDING, FT_NATIVE_OK], for: pending)
    for pointer in [first, pending] {
      pool.adopt(
        pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
        reportCleanup: { _ in failures.continuation.yield(()) },
        reportRetired: {
          script.recordReleased(pointer)
          releases.continuation.yield(UInt(bitPattern: pointer.value))
        })
    }
    var failed = failures.stream.makeAsyncIterator()
    _ = await failed.next()
    _ = await failed.next()
    let firstGate = script.holdNext(first)
    let pendingGate = script.holdNext(pending)
    let firstBatch = Task {
      await pool.retryFailed(cleanupOwnerID: owner)
      script.completeBatch()
    }
    let secondBatch = Task {
      await pool.retryFailed(cleanupOwnerID: owner)
      script.completeBatch()
    }
    var firstEntered = firstGate.entered.makeAsyncIterator()
    var pendingEntered = pendingGate.entered.makeAsyncIterator()
    _ = await firstEntered.next()
    _ = await pendingEntered.next()
    firstGate.release.signal()
    var released = releases.stream.makeAsyncIterator()
    #expect(await released.next() == UInt(bitPattern: first.value))
    #expect(script.completedBatches == 0 && !script.wasReleased(pending))
    // One selected Entry has gone, but a different factory's new Entry must not become a member.
    script.set([FT_NATIVE_OK], for: foreign)
    let foreignGate = script.holdNext(foreign)
    pool.adopt(
      foreign, lane: DispatchQueue(label: "fixture.foreign"), cleanupOwnerID: UUID(),
      reportCleanup: { _ in Issue.record("Unexpected foreign cleanup failure") },
      reportRetired: {
        script.recordReleased(foreign)
        releases.continuation.yield(UInt(bitPattern: foreign.value))
      })
    var foreignEntered = foreignGate.entered.makeAsyncIterator()
    _ = await foreignEntered.next()
    pendingGate.release.signal()
    #expect(await released.next() == UInt(bitPattern: pending.value))
    await firstBatch.value
    await secondBatch.value
    #expect(script.completedBatches == 2 && !script.wasReleased(foreign))
    #expect(script.calls(first) == 2 && script.calls(pending) == 3)
    foreignGate.release.signal()
    #expect(await released.next() == UInt(bitPattern: foreign.value))
    failures.continuation.finish()
    releases.continuation.finish()
  }

  @Test("An identical repeated failure stays retained for another explicit retry")
  func repeatedFailureDoesNotBecomeSuccess() async throws {
    let script = PoolRetirementScript()
    let pool = NativeRetirementPool(retireAndRelease: script.perform)
    let pointer = NativeRoutePointer(value: try #require(OpaquePointer(bitPattern: 0x3000)))
    let owner = UUID()
    let failures = AsyncStream<Int32>.makeStream()
    script.set([FT_NATIVE_FAILED, FT_NATIVE_FAILED, FT_NATIVE_OK], for: pointer)
    pool.adopt(
      pointer, lane: DispatchQueue(label: "fixture.route"), cleanupOwnerID: owner,
      reportCleanup: { failures.continuation.yield($0.code) },
      reportRetired: { script.recordReleased(pointer) })
    var iterator = failures.stream.makeAsyncIterator()
    #expect(await iterator.next() == -7302)
    await pool.retryFailed(cleanupOwnerID: owner)
    #expect(script.calls(pointer) == 2 && !script.wasReleased(pointer))
    // Both real errors carry the same code; equality must not suppress the second attempt.
    if script.calls(pointer) == 2 { #expect(await iterator.next() == -7302) }
    await pool.retryFailed(cleanupOwnerID: owner)
    #expect(script.calls(pointer) == 3 && script.wasReleased(pointer))
    failures.continuation.finish()
  }
}

private final class PoolRetirementScript: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [UInt: [FTNativeResult]] = [:]
  private var callCounts: [UInt: Int] = [:]
  private var released: Set<UInt> = []
  private struct Hold {
    let entered: AsyncStream<Void>.Continuation
    let release: DispatchSemaphore
  }
  private var holds: [UInt: Hold] = [:]
  private var batchCount = 0

  func holdNext(_ pointer: NativeRoutePointer) -> (
    entered: AsyncStream<Void>, release: DispatchSemaphore
  ) {
    let stream = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    lock.lock()
    holds[UInt(bitPattern: pointer.value)] = Hold(entered: stream.continuation, release: release)
    lock.unlock()
    return (stream.stream, release)
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
      hold.entered.yield(())
      hold.entered.finish()
      hold.release.wait()  // Only this injected NRT test operation is held, never an audio callback.
    }
    return NativeRouteResult(
      result: result, snapshot: FTNativeRouteSnapshot(),
      failure: result == FT_NATIVE_FAILED
        ? FTNativeError(kind: FT_NATIVE_FAILURE, operation: FT_NATIVE_DESTROY_IOPROC, code: -7302)
        : FTNativeError())
  }

  func recordReleased(_ pointer: NativeRoutePointer) {
    lock.lock()
    defer { lock.unlock() }
    released.insert(UInt(bitPattern: pointer.value))
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
