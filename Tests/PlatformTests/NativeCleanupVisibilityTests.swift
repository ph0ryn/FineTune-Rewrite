import FineTuneControl
import Testing

@testable import FineTunePlatform

/// These tests inject runtime events, not HAL owners. Actual pool release/failure behavior
/// remains a native/integration concern; a retired route snapshot is not a release event.
@Suite("Native cleanup visibility")
struct NativeCleanupVisibilityTests {
  private let first = AudioRouteKey(
    appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 1)
  private let second = AudioRouteKey(
    appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 2)
  private let failure = AudioRouteFailure(
    stage: "retire", code: -17, message: "Fixture cleanup failed")

  @Test @MainActor
  func independentFailedOwnersRemainKeyedUntilTheirMatchingRelease() {
    let runtime = makeRuntime()
    let firstObservation = observation(first)
    let secondObservation = observation(second)
    runtime.recordCleanup(first, failure: failure)
    runtime.recordCleanup(second, failure: failure)
    #expect(
      runtime.unresolvedCleanupFailures == [
        first: firstObservation, second: secondObservation,
      ])
    #expect(runtime.lastCleanupFailure == secondObservation)

    // A different successful owner must not imply that either failed owner was released.
    runtime.recordRetired(
      AudioRouteKey(appIdentifier: "another.app", deviceUID: "another-output", generation: 3))
    #expect(
      runtime.unresolvedCleanupFailures == [
        first: firstObservation, second: secondObservation,
      ])

    runtime.recordRetired(first)
    #expect(runtime.unresolvedCleanupFailures == [second: secondObservation])
    #expect(runtime.lastCleanupFailure == secondObservation)

    runtime.recordRetired(second)
    #expect(runtime.unresolvedCleanupFailures.isEmpty)
    #expect(runtime.lastCleanupFailure == secondObservation)
  }

  @Test @MainActor
  func changeNotificationsSeeUpdatedDebtAndPreserveFailureCallbackBehavior() {
    let runtime = makeRuntime()
    var changes: [[AudioRouteKey: AudioRouteObservation]] = []
    var failures: [AudioRouteObservation] = []
    runtime.onCleanupChange = { [weak runtime] in
      if let runtime { changes.append(runtime.unresolvedCleanupFailures) }
    }
    runtime.onCleanupFailure = { failures.append($0) }

    runtime.recordCleanup(first, failure: failure)
    runtime.recordCleanup(first, failure: failure)
    #expect(changes == [[first: observation(first)]])
    #expect(failures == [observation(first)])

    runtime.recordCleanup(second, failure: failure)
    runtime.recordRetired(first)
    runtime.recordRetired(first)
    runtime.recordRetired(second)
    #expect(
      changes == [
        [first: observation(first)],
        [first: observation(first), second: observation(second)],
        [second: observation(second)],
        [:],
      ])
    #expect(failures == [observation(first), observation(second)])
    #expect(runtime.lastCleanupFailure == observation(second))
  }

  @Test @MainActor
  func updatedFailureReplacesOnlyItsOwnDebt() {
    let runtime = makeRuntime()
    var notifications = 0
    runtime.onCleanupChange = { notifications += 1 }
    runtime.recordCleanup(first, failure: failure)
    runtime.recordCleanup(second, failure: failure)
    let updated = AudioRouteFailure(
      stage: "release", code: -18, message: "Fixture release failed")
    runtime.recordCleanup(first, failure: updated)
    let updatedObservation = AudioRouteObservation(
      key: first, phase: .failed, cleanupFailure: updated)
    #expect(
      runtime.unresolvedCleanupFailures == [
        first: updatedObservation, second: observation(second),
      ])
    #expect(runtime.lastCleanupFailure == updatedObservation)
    #expect(notifications == 3)
  }

  @Test @MainActor
  func historicalDuplicateCanBecomeUnresolvedAgainWithoutRepeatingFailureDiagnostic() {
    let runtime = makeRuntime()
    var changes = 0
    var failures = 0
    runtime.onCleanupChange = { changes += 1 }
    runtime.onCleanupFailure = { _ in failures += 1 }
    runtime.recordCleanup(first, failure: failure)
    runtime.recordRetired(first)
    runtime.recordCleanup(first, failure: failure)
    #expect(runtime.unresolvedCleanupFailures == [first: observation(first)])
    #expect(changes == 3)
    #expect(failures == 1)
  }

  @Test @MainActor
  func passiveVisibilityDoesNotResolveProcessesRetryOrClearDebt() {
    var resolutions = 0
    let runtime = NativeAudioRoutingRuntime(resolveApp: { identifier, _ in
      resolutions += 1
      throw AudioAppObservationResolutionError.unavailable(identifier)
    })
    var notifications = 0
    runtime.onCleanupChange = { notifications += 1 }
    runtime.recordCleanup(first, failure: failure)
    runtime.recordCleanup(second, failure: failure)

    // Recording debt is passive: it must not schedule process resolution or clear the debt.
    #expect(
      runtime.unresolvedCleanupFailures == [
        first: observation(first), second: observation(second),
      ])
    #expect(runtime.lastCleanupFailure == observation(second))
    #expect(resolutions == 0)
    #expect(notifications == 2)
  }

  @MainActor
  private func makeRuntime() -> NativeAudioRoutingRuntime {
    NativeAudioRoutingRuntime(resolveApp: { identifier, _ in
      Issue.record("Cleanup visibility must not resolve or prepare a process")
      throw AudioAppObservationResolutionError.unavailable(identifier)
    })
  }

  private func observation(_ key: AudioRouteKey) -> AudioRouteObservation {
    AudioRouteObservation(key: key, phase: .failed, cleanupFailure: failure)
  }
}
