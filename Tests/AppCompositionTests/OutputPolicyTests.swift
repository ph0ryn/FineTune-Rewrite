import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@Suite("Physical default-output policy through actual store and UID writer")
@MainActor
struct OutputPolicyTests {
  @Test(
    "Lower-priority hotplug restores the mid-priority user choice, including default-before-list ordering"
  )
  func lowerHotplugPreservesConfirmedUserChoice() {
    let (store, _) = fixture(["high", "mid", "low"])
    store.setDeviceRouting(for: "unit.pinned", deviceUID: "mid")
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) })
    defer { policy.suspend() }
    #expect(writes.isEmpty)
    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "mid", bluetoothUIDs: [])
    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "low", bluetoothUIDs: [])
    #expect(writes.isEmpty && policy.intendedDefaultUID == "mid")
    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
    #expect(writes == ["mid"] && policy.intendedDefaultUID == "mid")
    #expect(policy.observedDefaultUID == "low" && policy.graceDuration == .seconds(5))
    #expect(store.getDeviceRouting(for: "unit.pinned") == "mid")
  }

  @Test("Highest-priority reconnect wins without overwriting observed default or pinned app wishes")
  func highestReconnect() {
    let (store, _) = fixture(["high", "mid", "low"])
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["mid", "low"], defaultUID: "mid", bluetoothUIDs: [])
    policy.observe(availableUIDs: ["high", "mid", "low"], defaultUID: "mid", bluetoothUIDs: [])
    #expect(writes == ["high"] && policy.intendedDefaultUID == "high")
    #expect(policy.observedDefaultUID == "mid" && policy.graceDuration == .seconds(2))
  }

  @Test(
    "Explicit FineTune echo beats grace; a later settled System Settings change is respected",
    arguments: [false, true])
  func ownEchoAndSettledExternalChoice(explicitUI: Bool) throws {
    let (store, _) = fixture(["high", "mid", "low"])
    var writes: [String] = []
    let clock = DevicePolicyTestClock()
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) }, now: { clock.now })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "mid", bluetoothUIDs: [])
    policy.observe(
      availableUIDs: ["high", "mid", "low"], defaultUID: "mid", bluetoothUIDs: ["low"])
    if explicitUI {
      try policy.selectDefaultOutput(uid: "low")
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
      #expect(writes == ["low"] && policy.intendedDefaultUID == "low")
    } else {
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: "mid", bluetoothUIDs: ["low"])
      clock.now = 1.001
      policy.observe(
        availableUIDs: ["high", "mid", "low"], defaultUID: "low", bluetoothUIDs: ["low"])
      #expect(
        writes == ["mid"] && policy.intendedDefaultUID == "low" && policy.graceConnectionUID == nil)
    }
  }

  @Test("Failed priority write and failed discovery preserve actual default and durable priority")
  func priorityFailureAndObservationFailure() {
    let (store, directory) = fixture(["mid", "high"])
    var writes = 0
    let policy = OutputDevicePolicyController(
      settings: store,
      setDefaultOutput: { _ in
        writes += 1
        throw AudioRouteFailure(stage: "output-unit", message: "Failed default write")
      })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["high", "mid"], defaultUID: "mid", bluetoothUIDs: [])
    store.setDevicePriorityOrder(["high", "mid"])
    policy.settingsDidChange()
    #expect(writes == 1 && policy.lastFailure?.message == "Failed default write")
    #expect(policy.observedDefaultUID == "mid" && policy.intendedDefaultUID == "mid")
    policy.observe(
      availableUIDs: [], defaultUID: nil, bluetoothUIDs: [], failure: "Failed output discovery")
    #expect(
      policy.availableUIDs == ["high", "mid"] && policy.observedDefaultUID == "mid" && writes == 1)
    #expect(policy.lastFailure?.stage == "output-observation")
    store.flushSync()
    let reloaded = SettingsManager(
      directory: directory, launchAtLoginService: OutputPolicyLoginService())
    #expect(reloaded.devicePriorityOrder == ["high", "mid"])
  }

  @Test(
    "Reference-counted late echoes from rapid UI choices cannot overwrite the newest accepted intent"
  )
  func rapidOwnEchoesPreserveNewestChoice() throws {
    let (store, _) = fixture(["A", "B", "C", "X"])
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["A", "B", "C", "X"], defaultUID: "X", bluetoothUIDs: [])
    for uid in ["B", "C", "B", "A"] { try policy.selectDefaultOutput(uid: uid) }
    #expect(writes == ["B", "C", "B", "A"])
    for acknowledgement in ["A", "B", "C", "B"] {
      policy.observe(
        availableUIDs: ["A", "B", "C", "X"], defaultUID: acknowledgement, bluetoothUIDs: [])
      #expect(policy.intendedDefaultUID == "A")
    }
  }

  @Test("One hotplug batch registers unknown UIDs in the primary deterministic UID order")
  func unknownHotplugBatchPriorityRegistration() {
    let (store, _) = fixture(["old"])
    let policy = OutputDevicePolicyController(settings: store, setDefaultOutput: { _ in })
    defer { policy.suspend() }
    policy.observe(availableUIDs: ["old"], defaultUID: "old", bluetoothUIDs: [])
    policy.observe(availableUIDs: ["old", "z-new", "a-new"], defaultUID: "old", bluetoothUIDs: [])
    #expect(store.devicePriorityOrder == ["old", "a-new", "z-new"])
    #expect(policy.graceConnectionUID == "z-new")
  }

  @Test("Failed default observation forbids writes after grace and outstanding-echo clocks expire")
  func failedObservationBlocksExpiredEchoRetry() async throws {
    let (store, _) = fixture(["A", "B"])
    store.setDeviceRouting(for: "unit.pinned", deviceUID: "B")
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A"], defaultUID: "A", bluetoothUIDs: [])
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: [])
    try policy.selectDefaultOutput(uid: "B")
    var requests = clock.requests.stream.makeAsyncIterator()
    #expect(await requests.next() == .seconds(2))
    #expect(await requests.next() == .seconds(2))
    policy.observe(
      availableUIDs: [], defaultUID: nil, bluetoothUIDs: [], failure: "Default read failed")
    #expect(throws: AudioRouteFailure.self) { try policy.selectDefaultOutput(uid: "A") }
    clock.advance()
    var completions = clock.completions.stream.makeAsyncIterator()
    _ = await completions.next()
    _ = await completions.next()
    await Task.yield()
    #expect(writes == ["B"] && policy.lastFailure?.message == "Default read failed")
    #expect(policy.availableUIDs == ["A", "B"] && policy.observedDefaultUID == "A")
    #expect(policy.intendedDefaultUID == "B" && store.getDeviceRouting(for: "unit.pinned") == "B")
  }

  private func fixture(_ priority: [String]) -> (SettingsManager, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OutputPolicy-\(UUID().uuidString)")
    let store = SettingsManager(
      directory: directory, launchAtLoginService: OutputPolicyLoginService())
    store.setDevicePriorityOrder(priority)
    return (store, directory)
  }
}

@MainActor
private final class OutputPolicyLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
