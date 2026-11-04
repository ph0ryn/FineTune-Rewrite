import AppKit
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
  func flashRestoresTheLatestBaseline() async {
    let clock = RootIconClock()
    var baseline = MenuBarIconState.speakerVolume(.low)
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { baseline }, readDeviceSymbol: { "headphones" },
      apply: { applied.append($0) }, clock: DeviceBackendClock { try await clock.sleep($0) })
    coordinator.refresh()
    coordinator.flashDevice()
    #expect(applied.isEmpty)
    coordinator.start()
    coordinator.flashDevice()
    await clock.waitForSleeps(1)
    #expect(applied.last == .systemSymbol("headphones"))
    baseline = .speakerMuted
    coordinator.refresh()
    #expect(applied.last == .systemSymbol("headphones"))
    await clock.resume(0)
    await drainImageTasks()
    #expect(applied.last == .systemSymbol("speaker.slash.fill"))
    #expect(await clock.durations == [.seconds(1.1)])
    coordinator.stop()
  }

  @Test("Repeated flashes cancel old restores and stop prevents every late image application")
  func oldFlashAndStoppedCallbacksCannotApply() async {
    let clock = RootIconClock()
    var symbol = "headphones"
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { .speakerVolume(.high) }, readDeviceSymbol: { symbol },
      apply: { applied.append($0) }, clock: DeviceBackendClock { try await clock.sleep($0) })
    coordinator.start()
    coordinator.flashDevice()
    await clock.waitForSleeps(1)
    symbol = "hifispeaker.fill"
    coordinator.flashDevice()
    await clock.waitForSleeps(2)
    let latestFlash = applied.count
    await clock.resume(0)
    await drainImageTasks()
    #expect(applied.count == latestFlash)
    #expect(applied.last == .systemSymbol("hifispeaker.fill"))
    coordinator.stop()
    await clock.resume(1)
    await drainImageTasks()
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

  private func drainImageTasks() async {
    for _ in 0..<8 { await Task.yield() }
  }
}

private actor RootIconClock {
  private(set) var durations: [Duration] = []
  private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep(_ duration: Duration) async throws {
    let index = durations.count
    durations.append(duration)
    try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      let ready = waiters.filter { durations.count >= $0.0 }
      waiters.removeAll { durations.count >= $0.0 }
      for (_, waiter) in ready { waiter.resume() }
    }
  }

  func waitForSleeps(_ count: Int) async {
    guard durations.count < count else { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }

  func resume(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
}
