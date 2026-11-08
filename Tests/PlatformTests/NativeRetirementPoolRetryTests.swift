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

  func set(_ results: [FTNativeResult], for pointer: NativeRoutePointer) {
    lock.lock()
    defer { lock.unlock() }
    self.results[UInt(bitPattern: pointer.value)] = results
  }

  func perform(_ pointer: NativeRoutePointer) -> NativeRouteResult {
    lock.lock()
    defer { lock.unlock() }
    let key = UInt(bitPattern: pointer.value)
    callCounts[key, default: 0] += 1
    let result = results[key]!.removeFirst()
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
