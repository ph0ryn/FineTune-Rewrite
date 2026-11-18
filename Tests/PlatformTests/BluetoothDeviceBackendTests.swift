import FineTunePlatform
import Foundation
import Observation
import Testing

@Suite("Bluetooth device backend", .timeLimit(.minutes(1)))
@MainActor
struct BluetoothDeviceBackendTests {
  @Test("Construction is inert; observed paired audio devices are filtered and sorted")
  func observationsAndFiltering() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [
        peer("z", "Zulu"), peer("a", "Alpha"), peer("keyboard", "Keyboard", audio: false),
        peer("connected", "Connected", connected: true),
      ], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    #expect(await transport.snapshotCalls == 0)
    #expect(backend.isPoweredOn == nil && notifications.active == 0)
    backend.start()
    await backend.refresh()
    #expect(backend.isPoweredOn == true)
    #expect(backend.pairedDevices.map(\.id) == ["a", "z"])
    await transport.setPowered(false)
    await backend.refresh()
    #expect(backend.isPoweredOn == false && backend.pairedDevices.isEmpty)
    await stopAndDrain(backend: backend, transport: transport, clock: clock)
  }

  @Test(
    "A failed power read invalidates the previous on or off observation", arguments: [false, true])
  func failedPowerRead(previouslyPowered: Bool) async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    await transport.setPowered(previouslyPowered)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    #expect(backend.isPoweredOn == previouslyPowered)

    await transport.setSnapshotFailure(DeviceBackendError.osStatus(-5))
    await backend.refresh()
    #expect(backend.isPoweredOn == nil)
    #expect(backend.pairedDevices.isEmpty)
    #expect(backend.lastError != nil)

    await transport.setSnapshotFailure(nil)
    await transport.setPowered(true)
    await backend.refresh()
    #expect(backend.isPoweredOn == true)
    #expect(backend.pairedDevices.map(\.id) == ["a"])
    #expect(backend.lastError == nil)
    await stopAndDrain(backend: backend, transport: transport, clock: clock)
  }

  @Test("Startup and power notifications refresh without an explicit caller refresh")
  func automaticPowerRefresh() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    try await awaitObservationChange(
      waitedFor: "startup Bluetooth power refresh",
      observing: { _ = backend.isPoweredOn },
      trigger: { backend.start() })
    #expect(backend.isPoweredOn == true)
    #expect(await transport.snapshotCalls == 1)

    await transport.setPowered(false)
    try await awaitObservationChange(
      waitedFor: "Bluetooth power-off refresh",
      observing: { _ = backend.isPoweredOn },
      trigger: { notifications.callbacks.last?() })
    #expect(backend.isPoweredOn == false)

    await transport.setPowered(nil)
    try await awaitObservationChange(
      waitedFor: "Bluetooth unknown-power refresh",
      observing: { _ = backend.isPoweredOn },
      trigger: { notifications.callbacks.last?() })
    #expect(backend.isPoweredOn == nil)
    #expect(backend.lastError == nil)
    await stopAndDrain(backend: backend, transport: transport, clock: clock)
  }

  @Test("A failed power observation ends an in-flight request without publishing late SDK success")
  func failedPowerReadDuringConnection() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let request = Task { try await backend.connect(id: "a") }
        callerTasks.append(request)
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)

        await transport.setSnapshotFailure(DeviceBackendError.osStatus(-5))
        await backend.refresh()
        #expect(backend.isPoweredOn == nil)
        #expect(backend.connectionPhases["a"] == .failed)
        await transport.complete(id: "a")
        await #expect(throws: DeviceBackendError.osStatus(-5)) { try await request.value }
        #expect(backend.connectionPhases["a"] == .failed)
        #expect(backend.isPoweredOn == nil)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      })
  }

  @Test("Duplicate requests share one baseband operation and never claim an audio route")
  func duplicateConnect() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let first = Task { try await backend.connect(id: "a") }
        let second = Task { try await backend.connect(id: "a") }
        callerTasks = [first, second]
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)
        await transport.complete(id: "a")
        try await first.value
        try await second.value
        #expect(await transport.connectIDs == ["a"])
        #expect(backend.connectionPhases["a"] == .basebandConnected)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      })
  }

  @Test("A timeout is bounded independently of blocking SDK completion and clears its inline error")
  func timeoutAndLateCompletion() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let request = Task { try await backend.connect(id: "a") }
        callerTasks.append(request)
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)
        await clock.advance(by: .seconds(12))
        await #expect(
          throws: DeviceBackendError.operationFailed(
            "The Bluetooth connection timed out. It may still complete."
          )
        ) { try await request.value }
        #expect(backend.connectionPhases["a"] == .failed)
        #expect(backend.connectionErrors["a"] != nil)
        try await clock.waitForSleepCount(2)
        try await awaitObservationChange(
          waitedFor: "Bluetooth error clear after 4 seconds",
          observing: { _ = backend.lastError },
          trigger: { await clock.advance(by: .seconds(4)) })
        #expect(backend.connectionPhases["a"] == .idle)
        #expect(backend.connectionErrors.isEmpty && backend.lastError == nil)

        backend.stop()
        await transport.complete(id: "a")
        await clock.cancelAllSleeps()
        await Task.yield()
        #expect(backend.connectionPhases.isEmpty)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      })
  }

  @Test("Transient request failure clears public error state after its 4-second cooldown")
  func transientFailureClearsAfterCooldown() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        await #expect(throws: DeviceBackendError.unavailableDevice("missing")) {
          try await backend.connect(id: "missing")
        }
        #expect(backend.lastError != nil)
        #expect(backend.connectionErrors["missing"] != nil)
        #expect(backend.connectionPhases["missing"] == .failed)
        try await clock.waitForSleepCount(1)
        try await awaitObservationChange(
          waitedFor: "Bluetooth transient lastError to clear",
          observing: { _ = backend.lastError },
          trigger: { await clock.advance(by: .seconds(4)) })
        #expect(backend.lastError == nil)
        #expect(backend.connectionErrors.isEmpty)
        #expect(backend.connectionPhases["missing"] == .idle)
        await stopAndDrain(backend: backend, transport: transport, clock: clock)
      },
      cleanup: { await stopAndDrain(backend: backend, transport: transport, clock: clock) })
  }

  @Test("Power-off and unpaired identities cannot open a Bluetooth connection")
  func requestValidation() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    await #expect(throws: DeviceBackendError.unavailableDevice("not-paired")) {
      try await backend.connect(id: "not-paired")
    }
    await transport.setPowered(false)
    await backend.refresh()
    await #expect(
      throws: DeviceBackendError.operationFailed(
        "Turn on Bluetooth before connecting a device."
      )
    ) { try await backend.connect(id: "a") }
    #expect(await transport.connectIDs.isEmpty)
    await stopAndDrain(backend: backend, transport: transport, clock: clock)
  }

  @Test("An SDK failure stays visible when another device connects successfully")
  func independentConnectionFailure() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Alpha"), peer("z", "Zulu")], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let failed = Task { try await backend.connect(id: "a") }
        callerTasks.append(failed)
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)
        await transport.complete(id: "a", error: DeviceBackendError.osStatus(-5))
        await #expect(throws: DeviceBackendError.osStatus(-5)) { try await failed.value }
        #expect(backend.connectionPhases["a"] == .failed)
        try await clock.waitForSleepCount(2)

        let succeeded = Task { try await backend.connect(id: "z") }
        callerTasks.append(succeeded)
        try await transport.waitForConnectEntry(2)
        try await clock.waitForSleepCount(3)
        await transport.complete(id: "z")
        try await succeeded.value
        #expect(backend.connectionErrors["a"] != nil && backend.lastError != nil)
        #expect(backend.connectionPhases["z"] == .basebandConnected)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks)
      })
  }

  @Test("Stop removes power observers and rejects their late callbacks")
  func notificationLifetime() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let clock = ManualTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    #expect(notifications.active == 1)
    let callback = notifications.callbacks.first
    backend.stop()
    backend.stop()
    await transport.cancelPending()
    await clock.cancelAllSleeps()
    #expect(notifications.active == 0)
    let calls = await transport.snapshotCalls
    callback?()
    #expect(await transport.snapshotCalls == calls)
  }

  private func peer(_ id: String, _ name: String, audio: Bool = true, connected: Bool = false)
    -> BluetoothPeer
  {
    BluetoothPeer(id: id, name: name, isAudioDevice: audio, isConnected: connected)
  }

  private func stopAndDrain(
    backend: BluetoothDeviceBackend,
    transport: BluetoothFixtureTransport,
    clock: ManualTestClock,
    callerTasks: [Task<Void, any Error>] = []
  ) async {
    backend.stop()
    await transport.cancelPending()
    await clock.cancelAllSleeps()
    for task in callerTasks { _ = await task.result }
    await Task.yield()
  }
}

@MainActor
private final class BluetoothNotificationFixture {
  var active = 0
  var callbacks: [@MainActor @Sendable () -> Void] = []

  func observe(_ callback: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    active += 1
    callbacks.append(callback)
    return DevicePropertyObservation { [weak self] in self?.active -= 1 }
  }
}

private actor BluetoothFixtureTransport: BluetoothDeviceTransport {
  private let notifications: BluetoothNotificationFixture
  private var peers: [BluetoothPeer]
  private var powered: Bool? = true
  private var snapshotError: (any Error)?
  private var pending: [String: [CheckedContinuation<Void, any Error>]] = [:]
  private let connectEntries = CountSignal()
  var snapshotCalls = 0
  var connectIDs: [String] = []

  init(peers: [BluetoothPeer], notifications: BluetoothNotificationFixture) {
    self.peers = peers
    self.notifications = notifications
  }

  func snapshot() async throws -> BluetoothTransportSnapshot {
    snapshotCalls += 1
    if let snapshotError { throw snapshotError }
    return BluetoothTransportSnapshot(isPoweredOn: powered, peers: peers)
  }

  func setPowered(_ value: Bool?) { powered = value }
  func setSnapshotFailure(_ error: (any Error)?) { snapshotError = error }

  func connect(id: String) async throws {
    connectIDs.append(id)
    connectEntries.emit()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      pending[id, default: []].append(continuation)
    }
  }

  func complete(id: String, error: (any Error)? = nil) {
    for continuation in pending.removeValue(forKey: id) ?? [] {
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
  }

  func cancelPending() {
    connectEntries.cancelAll()
    let continuations = pending.values.flatMap { $0 }
    pending.removeAll()
    for continuation in continuations { continuation.resume(throwing: CancellationError()) }
  }

  func waitForConnectEntry(_ count: Int) async throws {
    do {
      try await connectEntries.wait(forCount: count, waitedFor: "Bluetooth connect entry \(count)")
    } catch {
      cancelPending()
      throw error
    }
  }

  @MainActor
  func observePowerChanges(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation { notifications.observe(onChange) }
}
