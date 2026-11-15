import AppTestSupport
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
    // Start the old grace delay before explicit selection cancels it; drain that cancelled wait too.
    #expect(try await clock.waitForNextRequest() == .seconds(2))
    try policy.selectDefaultOutput(uid: "B")
    #expect(try await clock.waitForNextRequest() == .seconds(2))
    policy.observe(
      availableUIDs: [], defaultUID: nil, bluetoothUIDs: [], failure: "Default read failed")
    #expect(throws: AudioRouteFailure.self) { try policy.selectDefaultOutput(uid: "A") }
    clock.advance()
    try await clock.waitForNextCompletion()
    try await clock.waitForNextCompletion()
    #expect(writes == ["B"] && policy.lastFailure?.message == "Default read failed")
    #expect(policy.availableUIDs == ["A", "B"] && policy.observedDefaultUID == "A")
    #expect(policy.intendedDefaultUID == "B" && store.getDeviceRouting(for: "unit.pinned") == "B")
  }

  @Test(
    "An explicit choice repairs one already-connected Bluetooth rebound, including a coalesced own ACK",
    arguments: [false, true], [0.2, 0.4])
  func explicitChoiceRepairsOneBluetoothRebound(observeInitialACK: Bool, reboundAt: Double) throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(policy.graceConnectionUID == nil)
    try policy.selectDefaultOutput(uid: "A")
    if observeInitialACK {
      clock.now = 0.05
      policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    }
    clock.now = reboundAt
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    #expect(policy.intendedDefaultUID == "A" && policy.observedDefaultUID == "B")
    #expect(policy.pendingDefaultUID == "A" && policy.lastFailure == nil)
    #expect(policy.routingDecision() == .routeToApprovedUID("A"))
    clock.now += 0.05
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    #expect(policy.observedDefaultUID == "A" && policy.intendedDefaultUID == "A")
    #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
    clock.now += 0.05
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    #expect(policy.observedDefaultUID == "B" && policy.intendedDefaultUID == "A")
    #expect(policy.lastFailure != nil)
    for instant in [0.8, 1.2, 1.8] {
      clock.now = instant
      policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
      #expect(writes == ["A", "A"] && policy.lastFailure != nil)
    }
    clock.now = 2.001
    // Expiring the correction window is not recovery or evidence of a new external choice.
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"] && policy.intendedDefaultUID == "A")
    #expect(policy.observedDefaultUID == "B" && policy.lastFailure != nil)
    try policy.selectDefaultOutput(uid: "B")  // Explicitly accept the already-observed output.
    #expect(writes == ["A", "A"] && policy.intendedDefaultUID == "B")
    #expect(policy.observedDefaultUID == "B" && policy.pendingDefaultUID == nil)
    #expect(policy.lastFailure == nil && policy.routingDecision() == .routeToApprovedUID("B"))
  }

  @Test("A rebound correction reserves its own acknowledgement before a reentrant writer")
  func correctiveEchoMayArriveInsideTheWriter() throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    weak var callbackPolicy: OutputDevicePolicyController?
    let policy = OutputDevicePolicyController(
      settings: store,
      setDefaultOutput: { uid in
        writes.append(uid)
        if writes.count == 2 {
          callbackPolicy?.observe(availableUIDs: ["A", "B"], defaultUID: uid, bluetoothUIDs: ["B"])
        }
      }, sleep: { try await clock.sleep($0) }, now: { clock.now })
    callbackPolicy = policy
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    #expect(policy.observedDefaultUID == "A" && policy.intendedDefaultUID == "A")
    #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
    clock.now = 0.4
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"] && policy.lastFailure != nil)
  }

  @Test("A late correction does not renew the fixed two-second explicit-choice settling interval")
  func correctionDoesNotExtendExplicitChoiceDeadline() throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 1.9
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"] && policy.intendedDefaultUID == "A")
    clock.now = 1.95
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 2.001
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    #expect(policy.intendedDefaultUID == "B" && policy.observedDefaultUID == "B")
    #expect(policy.lastFailure == nil && policy.routingDecision() == .routeToApprovedUID("B"))
  }

  @Test("A newer explicit output choice supersedes the earlier Bluetooth rebound target")
  func newerExplicitChoiceOwnsTheOnlyCorrection() throws {
    let (store, _) = fixture(["A", "C", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.1
    try policy.selectDefaultOutput(uid: "C")
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "C", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "C", "C"])
    #expect(policy.intendedDefaultUID == "C" && policy.observedDefaultUID == "B")
    #expect(policy.lastFailure == nil)
  }

  @Test(
    "Bluetooth rebound correction requires an accepted choice and a healthy current target",
    arguments: OutputReboundIneligibility.allCases)
  func reboundDoesNotBroadenUnhealthyOrUnselectedWrites(reason: OutputReboundIneligibility) throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store,
      setDefaultOutput: {
        writes.append($0)
        if reason == .rejectedSelection {
          throw AudioRouteFailure(stage: "output-write", message: "Explicit selection rejected")
        }
      }, sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    if reason == .rejectedSelection {
      #expect(throws: AudioRouteFailure.self) { try policy.selectDefaultOutput(uid: "A") }
    } else if reason != .noSelection {
      try policy.selectDefaultOutput(uid: "A")
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    if reason == .failedObservation {
      policy.observe(
        availableUIDs: [], defaultUID: nil, bluetoothUIDs: [], failure: "Default read failed")
      #expect(policy.lastFailure?.message == "Default read failed")
      #expect(policy.observedDefaultUID == "A")
    } else {
      policy.observe(
        availableUIDs: reason == .missingTarget ? ["B"] : ["A", "B"],
        defaultUID: "B", bluetoothUIDs: ["B"])
      #expect(policy.intendedDefaultUID == "B")
    }
    #expect(writes == (reason == .noSelection ? [] : ["A"]))
  }

  @Test(
    "A fresh external choice supersedes unacknowledged correction echoes and their old timeouts")
  func coalescedAcknowledgementTimeoutsStayBounded() async throws {
    let (store, _) = fixture(["A", "B", "C"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    #expect(try await clock.waitForNextRequest() == .seconds(2))
    clock.now = 0.4
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    let corrected = writes.count == 2
    if corrected { #expect(try await clock.waitForNextRequest() == .seconds(2)) }
    clock.now = 2.1
    // This changed healthy UID is new external intent, unlike replaying the same failed B.
    // The corrective A acknowledgement is still outstanding until its lease would expire at 2.4.
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "C", bluetoothUIDs: ["B"])
    #expect(policy.observedDefaultUID == "C" && policy.intendedDefaultUID == "C")
    #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
    #expect(policy.routingDecision() == .routeToApprovedUID("C"))
    clock.now = 2.401
    clock.advance()
    try await clock.waitForNextCompletion()
    if corrected { try await clock.waitForNextCompletion() }
    #expect(writes == ["A", "A"])
    #expect(policy.observedDefaultUID == "C" && policy.intendedDefaultUID == "C")
    #expect(policy.lastFailure == nil)
  }

  @Test(
    "Topology changes and suspension disarm explicit settling without overriding priority rules",
    arguments: [false, true])
  func topologyOrSuspensionDisarmsManualSettling(suspend: Bool) throws {
    let (store, _) = fixture(["C", "A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    if suspend {
      policy.suspend()
      policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
      policy.resume()
      #expect(writes == ["A"] && policy.intendedDefaultUID == "B")
    } else {
      policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
      #expect(writes == ["A", "C"] && policy.intendedDefaultUID == "C")
      #expect(policy.graceConnectionUID == "C")
    }
  }

  @Test("A rejected corrective write is visible and does not replenish the rebound budget")
  func failedBluetoothCorrectionDoesNotLoop() throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let failure = AudioRouteFailure(stage: "output-write", message: "Corrective write rejected")
    let policy = OutputDevicePolicyController(
      settings: store,
      setDefaultOutput: {
        writes.append($0)
        if writes.count > 1 { throw failure }
      }, sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"] && policy.lastFailure == failure)
    #expect(policy.intendedDefaultUID == "A" && policy.observedDefaultUID == "B")
    clock.now = 0.4
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.5
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"] && policy.lastFailure != nil)
  }

  @Test(
    "An explicit choice supersedes older Bluetooth hotplug grace, including after its fixed deadline"
  )
  func explicitChoiceRetiresOlderHotplugAuthority() throws {
    let (store, _) = fixture(["C", "A", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { writes.append($0) },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["C", "A"], defaultUID: "C", bluetoothUIDs: [])
    clock.now = -0.1
    policy.observe(availableUIDs: ["C", "A", "B"], defaultUID: "C", bluetoothUIDs: ["B"])
    #expect(policy.graceConnectionUID == "B")
    clock.now = 0
    try policy.selectDefaultOutput(uid: "A")
    #expect(policy.graceConnectionUID == nil)
    policy.observe(availableUIDs: ["C", "A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["C", "A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    clock.now = 0.35
    policy.observe(availableUIDs: ["C", "A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 2.1
    policy.observe(availableUIDs: ["C", "A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    #expect(writes == ["A", "A"])
    #expect(policy.observedDefaultUID == "B" && policy.intendedDefaultUID == "B")
    #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
  }

  @Test(
    "Reentrant corrective results survive an older writer returning successfully",
    arguments: [false, true])
  func correctiveWriterCannotEraseNewerResults(selectNewerOutput: Bool) throws {
    let (store, _) = fixture(["A", "C", "B"])
    let clock = DevicePolicyTestClock()
    var writes: [String] = []
    weak var callbackPolicy: OutputDevicePolicyController?
    let policy = OutputDevicePolicyController(
      settings: store,
      setDefaultOutput: { uid in
        writes.append(uid)
        guard writes.count == 2 else { return }
        callbackPolicy?.observe(
          availableUIDs: ["A", "B", "C"], defaultUID: "A", bluetoothUIDs: ["B"])
        if selectNewerOutput {
          try callbackPolicy?.selectDefaultOutput(uid: "C")
          callbackPolicy?.observe(
            availableUIDs: ["A", "B", "C"], defaultUID: "C", bluetoothUIDs: ["B"])
        } else {
          callbackPolicy?.observe(
            availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
        }
      }, sleep: { try await clock.sleep($0) }, now: { clock.now })
    callbackPolicy = policy
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["A", "B", "C"], defaultUID: "B", bluetoothUIDs: ["B"])
    if selectNewerOutput {
      #expect(writes == ["A", "A", "C"])
      #expect(policy.intendedDefaultUID == "C" && policy.observedDefaultUID == "C")
      #expect(policy.pendingDefaultUID == nil && policy.lastFailure == nil)
    } else {
      #expect(writes == ["A", "A"])
      #expect(policy.intendedDefaultUID == "A" && policy.observedDefaultUID == "B")
      #expect(policy.lastFailure?.stage == "output-selection")
    }
  }

  @Test("A default UID ahead of healthy inventory cannot clear an unresolved selection failure")
  func unknownDefaultCannotConfirmRecovery() throws {
    let (store, _) = fixture(["A", "B"])
    let clock = DevicePolicyTestClock()
    let policy = OutputDevicePolicyController(
      settings: store, setDefaultOutput: { _ in },
      sleep: { try await clock.sleep($0) }, now: { clock.now })
    defer {
      policy.suspend()
      clock.finish()
    }
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    try policy.selectDefaultOutput(uid: "A")
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.3
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "A", bluetoothUIDs: ["B"])
    clock.now = 0.6
    policy.observe(availableUIDs: ["A", "B"], defaultUID: "B", bluetoothUIDs: ["B"])
    let failure = try #require(policy.lastFailure)
    policy.observe(availableUIDs: [], defaultUID: "A", bluetoothUIDs: [])
    #expect(policy.lastFailure == failure)
    policy.observe(availableUIDs: ["A"], defaultUID: "A", bluetoothUIDs: [])
    #expect(policy.lastFailure == nil)
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

enum OutputReboundIneligibility: CaseIterable, Equatable, Sendable {
  case noSelection, rejectedSelection, missingTarget, failedObservation
}

@MainActor
private final class OutputPolicyLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
