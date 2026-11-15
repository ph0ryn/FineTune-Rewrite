import AppKit
import AppTestSupport
import FineTuneDomain
import FineTunePlatform
import Testing

@testable import FineTune

@Suite("Root menu-bar image ownership", .timeLimit(.minutes(1)))
@MainActor
struct RootLiveStateTests {
  @Test("Device-style symbols use the cached default device and its valid saved override")
  func deviceIconUsesTheActualCachedDevice() {
    let outputs = [
      AudioDevice(
        id: 11, uid: "speaker", name: "Built-in Speakers", icon: nil,
        supportsAutoEQ: false, bindingRevision: 1, transportType: .builtIn),
      AudioDevice(
        id: 22, uid: "headphones", name: "Headphones", icon: nil,
        supportsAutoEQ: true, bindingRevision: 1, transportType: .bluetooth),
    ]
    let symbol = ProductionRoot.menuBarDeviceSymbol(
      outputDevices: outputs, defaultDeviceID: 11, priorityOrder: ["headphones"],
      overrideForUID: { $0 == "speaker" ? "hifispeaker.fill" : nil })
    #expect(symbol == "hifispeaker.fill")
    #expect(
      ProductionRoot.menuBarDeviceSymbol(
        outputDevices: outputs, defaultDeviceID: 22, priorityOrder: ["speaker"],
        overrideForUID: { _ in nil })
        == DeviceIconSymbol.iconSymbol(forName: "Headphones", transport: .bluetooth))
  }

  @Test("The device flash restores the latest baseline rather than the one captured at its start")
  func flashRestoresTheLatestBaseline() async throws {
    let clock = RootIconClock()
    var baseline = MenuBarIconState.speakerVolume(.low)
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { baseline }, readDeviceSymbol: { "headphones" },
      apply: { applied.append($0) }, clock: DeviceBackendClock { try await clock.sleep($0) })
    // Stop ownership first so a drained sleep cannot apply a late image, then release any sleep
    // a failed wait or cancellation would otherwise leave parked for the rest of the suite.
    defer {
      coordinator.stop()
      clock.drainPendingSleeps()
    }
    coordinator.refresh()
    coordinator.flashDevice()
    #expect(applied.isEmpty)
    coordinator.start()
    coordinator.flashDevice()
    try await clock.waitForSleeps(1)
    #expect(applied.last == .systemSymbol("headphones"))
    baseline = .speakerMuted
    coordinator.refresh()
    #expect(applied.last == .systemSymbol("headphones"))
    clock.resume(0)
    #expect(try await clock.waitForCompletion() == 0)
    #expect(applied.last == .systemSymbol("speaker.slash.fill"))
    #expect(clock.durations == [.seconds(1.1)])
    coordinator.stop()
  }

  @Test("Repeated flashes cancel old restores and stop prevents every late image application")
  func oldFlashAndStoppedCallbacksCannotApply() async throws {
    let clock = RootIconClock()
    var symbol = "headphones"
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { .speakerVolume(.high) }, readDeviceSymbol: { symbol },
      apply: { applied.append($0) }, clock: DeviceBackendClock { try await clock.sleep($0) })
    // Stop ownership first so a drained sleep cannot apply a late image, then release any sleep
    // a failed wait or cancellation would otherwise leave parked for the rest of the suite.
    defer {
      coordinator.stop()
      clock.drainPendingSleeps()
    }
    coordinator.start()
    coordinator.flashDevice()
    try await clock.waitForSleeps(1)
    symbol = "hifispeaker.fill"
    coordinator.flashDevice()
    try await clock.waitForSleeps(2)
    let latestFlash = applied.count
    clock.resume(0)
    #expect(try await clock.waitForCompletion() == 0)
    #expect(applied.count == latestFlash)
    #expect(applied.last == .systemSymbol("hifispeaker.fill"))
    coordinator.stop()
    clock.resume(1)
    #expect(try await clock.waitForCompletion() == 1)
    coordinator.refresh()
    coordinator.flashDevice()
    #expect(applied.count == latestFlash)
    coordinator.start()
    #expect(applied.last == .systemSymbol("speaker.wave.3.fill"))
    coordinator.stop()
  }

  @Test("Application icon metadata is resolved once during explicit priming and never by rendering")
  func installedArtworkCacheIsPassive() {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    var resolved: [String] = []
    let cache = RootApplicationIconCache(resolve: { bundleID in
      resolved.append(bundleID)
      return bundleID == "unit.saved" ? image : nil
    })
    #expect(cache.icon(for: "unit.saved") == nil && cache.icon(for: nil) == nil)
    #expect(resolved.isEmpty)
    cache.prime(bundleIDs: ["unit.saved", "unit.missing"])
    for _ in 0..<3 {
      #expect(cache.icon(for: "unit.saved") === image)
      #expect(cache.icon(for: "unit.missing") == nil)
    }
    cache.prime(bundleIDs: ["unit.saved", "unit.missing"])
    #expect(resolved.count == 2 && Set(resolved) == ["unit.saved", "unit.missing"])
    cache.prime(bundleIDs: ["unit.new"])
    #expect(resolved.count == 3 && resolved.last == "unit.new")
  }

  @Test(
    "Bundled app clicks request LS reopen and report its real completion rather than activate alone",
    arguments: [false, true])
  func bundledApplicationReopenUsesRequiredPort(fails: Bool) throws {
    let url = URL(fileURLWithPath: "/Unit/Player.app", isDirectory: true)
    var activated = 0
    var reopened: [URL] = []
    var completion: (@MainActor (String?) -> Void)?
    var failure: String? = "Old error"
    ProductionRoot.activateApplication(
      bundleURL: url,
      activate: {
        activated += 1
        return true
      },
      reopen: {
        reopened.append($0)
        completion = $1
      }, reportFailure: { failure = $0 })
    #expect(activated == 0 && reopened == [url] && failure == nil)
    let finish = try #require(completion)
    let result = fails ? "Unit reopen denied" : nil
    finish(result)
    #expect(failure == result)
  }

  @Test("Standalone apps without bundle URLs keep activation and expose a failed activation")
  func standaloneApplicationUsesActivation() {
    var activated = 0
    var failure: String?
    ProductionRoot.activateApplication(
      bundleURL: nil,
      activate: {
        activated += 1
        return false
      },
      reopen: { _, _ in Issue.record("Standalone apps have no LS bundle to reopen") },
      reportFailure: { failure = $0 })
    #expect(activated == 1 && failure == "The application could not be activated.")
  }
}

@MainActor
private final class RootIconClock {
  private(set) var durations: [Duration] = []
  /// Yielded once the awaiting sleep returns, giving restore tests a completion boundary.
  let completions = AsyncStream<Int>.makeStream()
  private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var gateWaiters: [Int: RootIconGateWaiter] = [:]
  private var nextGateWaiterID = 0
  /// Sticky cleanup latch: once set, no sleep may register a fresh continuation.
  private var isDraining = false

  func sleep(_ duration: Duration) async throws {
    try Task.checkCancellation()
    guard !isDraining else { throw CancellationError() }
    let index = durations.count
    durations.append(duration)
    try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      resumeSatisfiedGateWaiters()
    }
    completions.continuation.yield(index)
  }

  /// Cumulative event gate: waits until `count` sleeps have been requested in total.
  ///
  /// A canceled wait resumes with `CancellationError`; a wait that reaches its one 5-second
  /// deadline throws `RootIconGateTimeout`, so a missing registration fails the test.
  func waitForSleeps(_ count: Int) async throws {
    guard durations.count < count else { return }
    let waiterID = nextGateWaiterID
    nextGateWaiterID += 1
    let failureDeadline: Duration = .seconds(5)
    try await withTaskCancellationHandler {
      _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        // One explicit deadline per wait keeps the cumulative gate bounded without polling.
        let timeout = Task { @MainActor [weak self] in
          try? await Task.sleep(for: failureDeadline)
          guard !Task.isCancelled else { return }
          self?.expireGateWaiter(waiterID, failureDeadline: failureDeadline)
        }
        gateWaiters[waiterID] = RootIconGateWaiter(
          target: count, continuation: continuation, timeout: timeout)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelGateWaiter(waiterID)
      }
    }
  }

  func resume(_ index: Int) {
    pending.removeValue(forKey: index)?.resume()
  }

  func waitForCompletion() async throws -> Int {
    try await waitForTestStreamElement(
      of: completions.stream, finishing: completions.continuation,
      waitedFor: "root icon sleep completion")
  }

  /// Cleanup-only release of every parked sleep so no flash task outlives a failed or canceled wait.
  ///
  /// Successful paths still release each sleep explicitly with `resume(_:)`. A drained sleep throws
  /// instead of yielding to `completions`, so cleanup cannot fabricate a completion or late image.
  /// The latch is set before releasing so a restore task that only reaches `sleep` after this drain
  /// fails immediately instead of parking a continuation the cleanup already left behind.
  func drainPendingSleeps() {
    isDraining = true
    let parked = Array(pending.values)
    pending.removeAll()
    for continuation in parked { continuation.resume(throwing: CancellationError()) }
  }

  private func resumeSatisfiedGateWaiters() {
    for waiterID in gateWaiters.filter({ durations.count >= $0.value.target }).keys {
      guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { continue }
      waiter.timeout.cancel()
      waiter.continuation.resume()
    }
  }

  /// Fails the one gate wait whose cumulative target was never reached within the deadline.
  private func expireGateWaiter(_ waiterID: Int, failureDeadline: Duration) {
    guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { return }
    waiter.continuation.resume(
      throwing: RootIconGateTimeout(
        failureDeadline: failureDeadline, expectedCount: waiter.target,
        observedDurations: durations))
  }

  private func cancelGateWaiter(_ waiterID: Int) {
    guard let waiter = gateWaiters.removeValue(forKey: waiterID) else { return }
    waiter.timeout.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }
}

/// One pending cumulative registration wait and its single bounded failure task.
private struct RootIconGateWaiter {
  let target: Int
  let continuation: CheckedContinuation<Void, any Error>
  let timeout: Task<Void, Never>
}

/// The clock's cumulative sleep-registration gate missed its single failure deadline.
private struct RootIconGateTimeout: Error, CustomStringConvertible, Sendable {
  let failureDeadline: Duration
  let expectedCount: Int
  let observedDurations: [Duration]

  var description: String {
    "Timed out after \(failureDeadline) waiting for sleep registration total "
      + "\(expectedCount); observed \(observedDurations.count) request(s): \(observedDurations)."
  }
}
