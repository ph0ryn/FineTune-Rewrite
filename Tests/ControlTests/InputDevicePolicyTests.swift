import FineTuneControl
import FineTuneDomain
import Testing

@Suite("Control: Input device preference policy", .timeLimit(.minutes(1)))
@MainActor
struct InputDevicePolicyTests {
  private func makeStore(lockInput: Bool = true) -> InMemoryControlSettingsStore {
    let store = InMemoryControlSettingsStore()
    var settings = store.appSettings
    settings.lockInputDevice = lockInput
    store.updateAppSettings(settings)
    return store
  }

  @Test(
    "Priority fallback changes the current lock, never preferred wish; reconnect restores preferred"
  )
  func disconnectAndReconnectPreserveWish() {
    let store = makeStore()
    store.setPreferredInputDeviceUID("headset")
    store.setLockedInputDeviceUID("headset")
    store.setInputDevicePriorityOrder(["usb", "built-in", "headset"])
    var writes: [String] = []
    let policy = InputDevicePolicyController(
      settings: store, setDefaultInput: { writes.append($0) })
    defer { policy.suspend() }

    policy.observe(
      availableUIDs: ["built-in", "usb", "headset"], defaultUID: "headset",
      builtInUIDs: ["built-in"], bluetoothUIDs: ["headset"])
    policy.observe(
      availableUIDs: ["built-in", "usb"], defaultUID: "built-in",
      builtInUIDs: ["built-in"], bluetoothUIDs: [])
    #expect(store.preferredInputDeviceUID == "headset" && store.lockedInputDeviceUID == "usb")
    #expect(writes == ["usb"] && policy.observedDefaultUID == "built-in")

    policy.observe(
      availableUIDs: ["built-in", "usb", "headset"], defaultUID: "usb",
      builtInUIDs: ["built-in"], bluetoothUIDs: ["headset"])
    #expect(writes == ["usb", "headset"] && store.lockedInputDeviceUID == "headset")
    #expect(policy.observedDefaultUID == "usb")
  }

  @Test(
    "Writer failure preserves explicit wishes and last-good discovery, never optimistic default")
  func failedWriteAndObservationAreVisible() throws {
    let store = makeStore()
    var calls = 0
    let failure = AudioRouteFailure(stage: "input-unit", message: "UID writer failed")
    let policy = InputDevicePolicyController(
      settings: store,
      setDefaultInput: { _ in
        calls += 1
        throw failure
      })
    defer { policy.suspend() }

    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "built-in",
      builtInUIDs: ["built-in"], bluetoothUIDs: ["headset"])
    #expect(throws: AudioRouteFailure.self) { try policy.selectPreferredInput(uid: "headset") }
    #expect(store.preferredInputDeviceUID == "headset" && store.lockedInputDeviceUID == "headset")
    #expect(policy.observedDefaultUID == "built-in" && policy.lastFailure != nil && calls == 1)

    policy.observe(
      availableUIDs: [], defaultUID: nil, builtInUIDs: [], bluetoothUIDs: [],
      failure: "Discovery failed")
    #expect(
      policy.availableUIDs == ["built-in", "headset"] && policy.observedDefaultUID == "built-in")
    #expect(calls == 1 && policy.lastFailure?.stage == "input-observation")
  }

  @Test("Lock enable captures the observed default; unlocked observations do not force writes")
  func enablingLockUsesObservedDefault() {
    let store = makeStore(lockInput: false)
    var writes: [String] = []
    let policy = InputDevicePolicyController(
      settings: store, setDefaultInput: { writes.append($0) })
    defer { policy.suspend() }
    #expect(writes.isEmpty)

    policy.observe(
      availableUIDs: ["built-in", "usb"], defaultUID: "usb",
      builtInUIDs: ["built-in"], bluetoothUIDs: [])
    #expect(writes.isEmpty && store.preferredInputDeviceUID == nil)

    var settings = store.appSettings
    settings.lockInputDevice = true
    store.updateAppSettings(settings)
    policy.settingsDidChange()
    #expect(
      store.lockedInputDeviceUID == "usb" && store.preferredInputDeviceUID == "usb"
        && writes.isEmpty)
  }

  @Test("A repeated headset-mode re-assertion after one lock correction is deferred to")
  func inputReassertionAfterOneCorrectionIsAccepted() {
    let store = makeStore()
    store.setLockedInputDeviceUID("built-in")
    store.setPreferredInputDeviceUID("built-in")
    var writes: [String] = []
    let policy = InputDevicePolicyController(
      settings: store, setDefaultInput: { writes.append($0) })
    defer { policy.suspend() }

    policy.observe(
      availableUIDs: ["built-in"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: [])
    // The headset-mode input appears with macOS already switched to it.
    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "headset", builtInUIDs: ["built-in"],
      bluetoothUIDs: ["headset"])
    #expect(writes == ["built-in"])

    // Our correction's acknowledgement, then the OS re-asserting its choice.
    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: ["headset"])
    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "headset", builtInUIDs: ["built-in"],
      bluetoothUIDs: ["headset"])
    #expect(writes == ["built-in"] && policy.observedDefaultUID == "headset")

    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "headset", builtInUIDs: ["built-in"],
      bluetoothUIDs: ["headset"])
    #expect(writes == ["built-in"])
  }

  @Test(
    "Grace follows pinned non-BT two seconds / BT and BLE five seconds", arguments: [false, true])
  func connectionGraceUsesObservedTransport(bluetooth: Bool) async throws {
    let store = makeStore()
    store.setLockedInputDeviceUID("built-in")
    store.setPreferredInputDeviceUID("built-in")
    let clock = ControlManualTestClock()
    var writes: [String] = []
    let policy = InputDevicePolicyController(
      settings: store, setDefaultInput: { writes.append($0) }, sleep: { try await clock.sleep($0) })
    defer {
      policy.suspend()
      clock.finish()
    }

    policy.observe(
      availableUIDs: ["built-in"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: [])
    policy.observe(
      availableUIDs: ["built-in", "new"], defaultUID: "built-in",
      builtInUIDs: ["built-in"], bluetoothUIDs: bluetooth ? ["new"] : [])
    #expect(policy.graceConnectionUID == "new")
    #expect(policy.graceDuration == .seconds(bluetooth ? 5 : 2))
    #expect(try await clock.waitForNextRequest() == .seconds(bluetooth ? 5 : 2))

    policy.observe(
      availableUIDs: [], defaultUID: nil, builtInUIDs: [], bluetoothUIDs: [],
      failure: "Input read failed")
    clock.advance()
    try await clock.waitForNextCompletion()
    #expect(writes.isEmpty && policy.lastFailure?.message == "Input read failed")
    #expect(policy.availableUIDs == ["built-in", "new"] && policy.observedDefaultUID == "built-in")
    #expect(store.preferredInputDeviceUID == "built-in")
    policy.suspend()
    #expect(policy.graceConnectionUID == nil)
  }

  @Test("Disconnecting the graced input cancels grace, and resume restores preferred lock")
  func graceCancellationAndResume() {
    let store = makeStore()
    store.setPreferredInputDeviceUID("headset")
    store.setLockedInputDeviceUID("built-in")
    let clock = ControlManualTestClock()
    var writes: [String] = []
    let policy = InputDevicePolicyController(
      settings: store, setDefaultInput: { writes.append($0) }, sleep: { try await clock.sleep($0) })
    defer {
      policy.suspend()
      clock.finish()
    }

    policy.observe(
      availableUIDs: ["built-in"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: [])
    policy.observe(
      availableUIDs: ["built-in", "usb"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: [])
    #expect(policy.graceConnectionUID == "usb")

    policy.observe(
      availableUIDs: ["built-in"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: [])
    #expect(policy.graceConnectionUID == nil)

    policy.suspend()
    policy.observe(
      availableUIDs: ["built-in", "headset"], defaultUID: "built-in", builtInUIDs: ["built-in"],
      bluetoothUIDs: ["headset"])
    #expect(writes.isEmpty)
    policy.resume()
    #expect(store.lockedInputDeviceUID == "headset")
    #expect(writes == ["headset"])
  }
}
