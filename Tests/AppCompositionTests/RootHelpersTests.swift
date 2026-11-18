import AppKit
import AppTestSupport
import FineTuneDomain
import FineTunePlatform
import Testing

@testable import FineTune

@Suite(
  "App composition: Root menu-bar icon, artwork cache, and app activation helpers",
  .timeLimit(.minutes(1)))
@MainActor
struct RootHelpersTests {
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
    let clock = DevicePolicyTestClock()
    var baseline = MenuBarIconState.speakerVolume(.low)
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { baseline }, readDeviceSymbol: { "headphones" },
      apply: { applied.append($0) },
      clock: DeviceBackendClock { try await clock.sleep($0) })
    defer {
      coordinator.stop()
      clock.finish()
    }

    coordinator.refresh()
    coordinator.flashDevice()
    #expect(applied.isEmpty)
    coordinator.start()
    coordinator.flashDevice()
    #expect(try await clock.waitForNextRequest() == .seconds(1.1))
    #expect(applied.last == .systemSymbol("headphones"))
    baseline = .speakerMuted
    coordinator.refresh()
    #expect(applied.last == .systemSymbol("headphones"))
    clock.advance()
    try await clock.waitForNextCompletion()
    #expect(applied.last == .systemSymbol("speaker.slash.fill"))
    coordinator.stop()
  }

  @Test("Repeated flashes cancel old restores and stop prevents late image application")
  func oldFlashAndStoppedCallbacksCannotApply() async throws {
    let clock = DevicePolicyTestClock()
    var symbol = "headphones"
    var applied: [MenuBarIconImage] = []
    let coordinator = RootMenuBarIconCoordinator(
      readBaseline: { .speakerVolume(.high) }, readDeviceSymbol: { symbol },
      apply: { applied.append($0) }, clock: DeviceBackendClock { try await clock.sleep($0) })
    defer {
      coordinator.stop()
      clock.finish()
    }

    coordinator.start()
    coordinator.flashDevice()
    #expect(try await clock.waitForNextRequest() == .seconds(1.1))
    symbol = "hifispeaker.fill"
    coordinator.flashDevice()
    #expect(try await clock.waitForNextRequest() == .seconds(1.1))
    let latestFlash = applied.count

    clock.advance()
    try await clock.waitForNextCompletion()
    try await clock.waitForNextCompletion()
    #expect(applied.count == latestFlash + 1)
    #expect(applied.last == .systemSymbol("speaker.wave.3.fill"))

    coordinator.stop()
    coordinator.refresh()
    coordinator.flashDevice()
    #expect(applied.count == latestFlash + 1)
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
