// Independently authored coverage for real HUD presentation and timer/resource behavior.
// Split from the GPL-derived upstream suite per the manifest D records; no upstream body is copied.

import AppKit
import FineTunePlatform
import Testing

@testable import FineTune

/// Local ServiceManagement boundary; never registers the real app for login.
@MainActor
private final class IndependentLaunchAtLoginService: LaunchAtLoginService {
  private(set) var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@Suite("Rewrite HUD presentation lifecycle", .serialized)
@MainActor
struct RewriteHUDLifecycleTests {
  init() { _ = NSApplication.shared }

  private func controller(clock: DeviceBackendClock = .continuous) -> HUDWindowController {
    let settings = SettingsManager(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      launchAtLoginService: IndependentLaunchAtLoginService()
    )
    let hud = HUDWindowController(
      settingsManager: settings, mediaKeyStatus: MediaKeyStatus(),
      popupVisibility: PopupVisibilityService(), clock: clock
    )
    hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }
    hud.fullscreenProvider = { false }
    return hud
  }

  @Test("Fullscreen suppression is preserved independently of the popup/timer fixtures")
  func fullscreenSuppression() {
    let hud = controller()
    defer { hud.shutdown() }
    hud.fullscreenProvider = { true }
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Fixture")
    #expect(hud.showCallCount == 1)
    #expect(!hud.showDidUpdatePanel)
    #expect(!hud.isVisible)
  }

  @Test("The actual panel is presented and then hidden by the deadline")
  func panelAutoHide() async throws {
    let clock = HUDDeadlineClock()
    let hud = controller(clock: DeviceBackendClock { try await clock.sleep($0) })
    defer { hud.shutdown() }
    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Fixture")
    #expect(hud.isVisible)
    #expect(hud.showDidUpdatePanel)
    try await clock.waitForSleeps(1)
    let deadline = try #require(hud.hideTask)
    let requested = await clock.requestedDurations
    #expect(requested == [.milliseconds(1100)])
    await clock.releaseSleep(0)
    await deadline.value
    #expect(!hud.isVisible)
  }

  @Test("The clock receives the production default and the override exactly")
  func requestedHideDelays() async throws {
    let clock = HUDDeadlineClock()
    let hud = controller(clock: DeviceBackendClock { try await clock.sleep($0) })
    defer { hud.shutdown() }

    hud.show(sliderFraction: 0.4, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(1)
    let defaultDeadline = try #require(hud.hideTask)
    var requested = await clock.requestedDurations
    #expect(requested == [.milliseconds(1100)])
    await clock.releaseSleep(0)
    await defaultDeadline.value
    #expect(!hud.isVisible)

    hud.hideDelayOverride = .milliseconds(250)
    hud.show(sliderFraction: 0.6, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(2)
    let overriddenDeadline = try #require(hud.hideTask)
    requested = await clock.requestedDurations
    #expect(requested == [.milliseconds(1100), .milliseconds(250)])
    await clock.releaseSleep(1)
    await overriddenDeadline.value
    #expect(!hud.isVisible)

    hud.hideDelayOverride = .milliseconds(1500)
    hud.show(sliderFraction: 0.6, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(3)
    let secondOverride = try #require(hud.hideTask)
    requested = await clock.requestedDurations
    #expect(
      requested == [.milliseconds(1100), .milliseconds(250), .milliseconds(1500)])
    await clock.releaseSleep(2)
    await secondOverride.value
    #expect(!hud.isVisible)
  }

  @Test("A canceled hide task cannot hide a newer presentation")
  func timerResetAndShutdown() async throws {
    let clock = HUDDeadlineClock()
    let hud = controller(clock: DeviceBackendClock { try await clock.sleep($0) })
    defer { hud.shutdown() }

    hud.hideDelayOverride = .milliseconds(20)
    hud.show(sliderFraction: 0.2, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(1)
    let staleDeadline = try #require(hud.hideTask)

    hud.hideDelayOverride = .seconds(1)
    hud.show(sliderFraction: 0.8, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(2)
    let replacement = try #require(hud.hideTask)
    let requested = await clock.requestedDurations
    #expect(requested == [.milliseconds(20), .seconds(1)])

    // Release the canceled deadline and await its exact completion: it must not hide the
    // presentation that scheduled the replacement.
    await clock.releaseSleep(0)
    await staleDeadline.value
    #expect(hud.isVisible)

    // The replacement deadline is still pending, so only releasing it may hide the panel.
    await clock.releaseSleep(1)
    await replacement.value
    #expect(!hud.isVisible)

    hud.show(sliderFraction: 0.5, mute: false, deviceName: "Fixture")
    try await clock.waitForSleeps(3)
    let shutdownDeadline = try #require(hud.hideTask)
    hud.shutdown()
    #expect(!hud.isVisible)
    #expect(hud.hideTask == nil)
    // Releasing the canceled deadline after shutdown cannot resurrect or reorder the panel.
    await clock.releaseSleep(2)
    await shutdownDeadline.value
    #expect(!hud.isVisible)
  }
}

/// Deterministic hide-deadline gate: sleeps never elapse until the test releases them.
///
/// Registration is a cumulative event gate: each wait returns once the total number of fake
/// sleeps requested by production reaches its target. One explicit deadline per wait turns a
/// missed registration into a thrown failure instead of an indefinitely suspended continuation.
private actor HUDDeadlineClock {
  private(set) var requestedDurations: [Duration] = []
  private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var gateWaiters: [Int: HUDGateWaiter] = [:]
  private var nextGateWaiterID = 0

  /// Records the exact requested duration, then suspends until released or canceled.
  ///
  /// Cancellation (a timer reset or `hud.shutdown()`) resumes the continuation with
  /// `CancellationError`, so production's `catch` completes the hide task instead of leaking it.
  func sleep(_ duration: Duration) async throws {
    let index = requestedDurations.count
    requestedDurations.append(duration)
    // Pin the continuation's result type and keep it out of the operation's return position:
    // Swift 6.4.2 otherwise fails to type-check this cancellation-handler call and reports only
    // "failed to produce diagnostic for expression". The sleep behavior is unchanged.
    try await withTaskCancellationHandler {
      _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        pending[index] = continuation
        resumeSatisfiedGateWaiters()
      }
    } onCancel: {
      Task { await self.cancelSleep(index) }
    }
  }

  /// Cumulative event gate: waits until `count` sleeps have been requested in total.
  ///
  /// A canceled wait resumes with `CancellationError`; a wait that reaches its one 5-second
  /// deadline throws `HUDDeadlineTimeout`, so a missing registration fails the test.
  func waitForSleeps(_ count: Int) async throws {
    guard requestedDurations.count < count else { return }
    let waiterID = nextGateWaiterID
    nextGateWaiterID += 1
    let failureDeadline: Duration = .seconds(5)
    // Same Swift 6.4.2 workaround as above: pin the continuation type so the gate operation
    // returns Void. The cumulative gate and its single failure deadline are unchanged.
    try await withTaskCancellationHandler {
      _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        // One explicit deadline per wait keeps the cumulative gate bounded without polling.
        let timeout = Task<Void, Never> { [weak self] in
          try? await Task.sleep(for: failureDeadline)
          guard !Task.isCancelled else { return }
          await self?.expireGateWaiter(waiterID, failureDeadline: failureDeadline)
        }
        gateWaiters[waiterID] = HUDGateWaiter(
          target: count, continuation: continuation, timeout: timeout)
      }
    } onCancel: {
      Task { await self.cancelGateWaiter(waiterID) }
    }
  }

  func releaseSleep(_ index: Int) {
    pending.removeValue(forKey: index)?.resume()
  }

  /// A canceled hide task must complete its fake sleep instead of leaving the continuation
  /// suspended after `hud.shutdown()` or a timer reset.
  private func cancelSleep(_ index: Int) {
    pending.removeValue(forKey: index)?.resume(throwing: CancellationError())
  }

  private func resumeSatisfiedGateWaiters() {
    for waiterID in gateWaiters.filter({ requestedDurations.count >= $0.value.target }).keys {
      guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { continue }
      waiter.timeout.cancel()
      waiter.continuation.resume()
    }
  }

  /// Fails the one gate wait whose cumulative target was never reached within the deadline.
  private func expireGateWaiter(_ waiterID: Int, failureDeadline: Duration) {
    guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { return }
    waiter.continuation.resume(
      throwing: HUDDeadlineTimeout(
        failureDeadline: failureDeadline, expectedCount: waiter.target,
        observedDurations: requestedDurations))
  }

  private func cancelGateWaiter(_ waiterID: Int) {
    guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { return }
    waiter.timeout.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }
}

/// One pending cumulative registration wait and its single bounded failure task.
nonisolated private struct HUDGateWaiter {
  let target: Int
  let continuation: CheckedContinuation<Void, any Error>
  let timeout: Task<Void, Never>
}

/// The clock's cumulative sleep-registration gate missed its single failure deadline.
nonisolated private struct HUDDeadlineTimeout: Error, CustomStringConvertible, Sendable {
  let failureDeadline: Duration
  let expectedCount: Int
  let observedDurations: [Duration]

  var description: String {
    "Timed out after \(failureDeadline) waiting for sleep registration total "
      + "\(expectedCount); observed \(observedDurations.count) request(s): \(observedDurations)."
  }
}
