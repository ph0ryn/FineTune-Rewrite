import Foundation
import Testing

@testable import FineTunePlatform

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
    let clock = DeviceBackendTestClock()
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
    let backend = BluetoothDeviceBackend(transport: transport, clock: .continuous)
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
    backend.stop()
  }

  @Test("Startup and power notifications refresh without an explicit caller refresh")
  func automaticPowerRefresh() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let backend = BluetoothDeviceBackend(transport: transport, clock: .continuous)
    backend.start()
    try await waitForScheduledRefresh(backend)
    #expect(backend.isPoweredOn == true)
    #expect(await transport.snapshotCalls == 1)

    await transport.setPowered(false)
    notifications.callbacks.last?()
    try await waitForScheduledRefresh(backend)
    #expect(backend.isPoweredOn == false)
    await transport.setPowered(nil)
    notifications.callbacks.last?()
    try await waitForScheduledRefresh(backend)
    #expect(backend.isPoweredOn == nil)
    #expect(backend.lastError == nil)
    backend.stop()
  }

  @Test("A failed power observation ends an in-flight request without publishing late SDK success")
  func failedPowerReadDuringConnection() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    var connectionTasksForCleanup: [Task<Void, Never>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let request = Task { try await backend.connect(id: "a") }
        callerTasks.append(request)
        try await transport.waitForConnectEntry(1)
        let operation = try #require(backend.connectionOperation(for: "a"))
        try await clock.waitForSleepCount(1)
        connectionTasksForCleanup.append(contentsOf: backend.currentConnectionTasks())

        await transport.setSnapshotFailure(DeviceBackendError.osStatus(-5))
        await backend.refresh()
        #expect(backend.isPoweredOn == nil)
        #expect(backend.connectionPhases["a"] == .failed)
        await transport.complete(id: "a")
        await operation.value
        await #expect(throws: DeviceBackendError.osStatus(-5)) { try await request.value }
        #expect(backend.connectionPhases["a"] == .failed)
        #expect(backend.isPoweredOn == nil)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      })
  }

  @Test("Duplicate requests share one baseband operation and never claim an audio route")
  func duplicateConnect() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    var connectionTasksForCleanup: [Task<Void, Never>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let first = Task { try await backend.connect(id: "a") }
        callerTasks.append(first)
        try await transport.waitForConnectEntry(1)
        let operation = try #require(backend.connectionOperation(for: "a"))
        let second = Task { try await backend.connect(id: "a") }
        callerTasks.append(second)
        try await clock.waitForSleepCount(1)
        connectionTasksForCleanup.append(contentsOf: backend.currentConnectionTasks())
        await transport.complete(id: "a")
        await operation.value
        try await first.value
        try await second.value
        #expect(await transport.connectIDs == ["a"])
        #expect(backend.connectionPhases["a"] == .basebandConnected)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      })
  }

  @Test("A timeout is bounded independently of blocking SDK completion and clears its inline error")
  func timeoutAndLateCompletion() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    var connectionTasksForCleanup: [Task<Void, Never>] = []
    var refreshTasksForCleanup: [Task<Void, Never>] = []
    var errorClearTasksForCleanup: [Task<Void, Never>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        if let refresh = backend.scheduledRefresh { refreshTasksForCleanup.append(refresh) }
        await backend.refresh()
        let request = Task { try await backend.connect(id: "a") }
        callerTasks.append(request)
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)
        let operation = try #require(backend.connectionOperation(for: "a"))
        connectionTasksForCleanup = backend.currentConnectionTasks()
        await clock.advance(by: .seconds(12))
        await #expect(
          throws: DeviceBackendError.operationFailed(
            "The Bluetooth connection timed out. It may still complete."
          )
        ) { try await request.value }
        #expect(backend.connectionPhases["a"] == .failed)
        #expect(backend.connectionErrors["a"] != nil)
        try await clock.waitForSleepCount(2)
        let errorClearTask = try #require(backend.currentErrorClearTasks()["a"])
        errorClearTasksForCleanup.append(errorClearTask)
        let cleared = TestCompletionEvent()
        backend.errorClearDidComplete = { id in
          if id == "a" { cleared.signal() }
        }
        await clock.advance(by: .seconds(4))
        await cleared.wait()
        await errorClearTask.value
        #expect(backend.connectionPhases["a"] == .idle)
        if let refresh = backend.scheduledRefresh { refreshTasksForCleanup.append(refresh) }
        backend.stop()
        await transport.complete(id: "a")
        await clock.cancelAllSleeps()
        await operation.value
        for task in connectionTasksForCleanup { await task.value }
        for task in refreshTasksForCleanup { await task.value }
        #expect(backend.connectionPhases.isEmpty)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup,
          additionalRefreshTasks: refreshTasksForCleanup,
          additionalErrorClearTasks: errorClearTasksForCleanup)
      })
  }

  @Test("Power-off and unpaired identities cannot open a Bluetooth connection")
  func requestValidation() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
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
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    var callerTasks: [Task<Void, any Error>] = []
    var connectionTasksForCleanup: [Task<Void, Never>] = []
    try await withFailureCleanup(
      operation: {
        backend.start()
        await backend.refresh()
        let failed = Task { try await backend.connect(id: "a") }
        callerTasks.append(failed)
        try await transport.waitForConnectEntry(1)
        try await clock.waitForSleepCount(1)
        let failedOperation = try #require(backend.connectionOperation(for: "a"))
        connectionTasksForCleanup.append(contentsOf: backend.currentConnectionTasks())
        await transport.complete(id: "a", error: DeviceBackendError.osStatus(-5))
        await failedOperation.value
        await #expect(throws: DeviceBackendError.osStatus(-5)) { try await failed.value }
        #expect(backend.connectionPhases["a"] == .failed)
        try await clock.waitForSleepCount(2)
        let succeeded = Task { try await backend.connect(id: "z") }
        callerTasks.append(succeeded)
        try await transport.waitForConnectEntry(2)
        try await clock.waitForSleepCount(3)
        let succeededOperation = try #require(backend.connectionOperation(for: "z"))
        connectionTasksForCleanup.append(contentsOf: backend.currentConnectionTasks())
        await transport.complete(id: "z")
        await succeededOperation.value
        try await succeeded.value
        #expect(backend.connectionErrors["a"] != nil && backend.lastError != nil)
        #expect(backend.connectionPhases["z"] == .basebandConnected)
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      },
      cleanup: {
        await stopAndDrain(
          backend: backend, transport: transport, clock: clock, callerTasks: callerTasks,
          additionalConnectionTasks: connectionTasksForCleanup)
      })
  }

  @Test("Stop removes power observers and rejects their late callbacks")
  func notificationLifetime() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    #expect(notifications.active == 1)
    let callback = notifications.callbacks.first
    let refreshTask = backend.scheduledRefresh
    let errorClearTasks = Array(backend.currentErrorClearTasks().values)
    backend.stop()
    backend.stop()
    await transport.cancelPending()
    await clock.cancelAllSleeps()
    if let refreshTask { await refreshTask.value }
    for task in errorClearTasks { await task.value }
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

  /// Waits for the exact refresh task the backend scheduled, not an observed power value.
  private func waitForScheduledRefresh(_ backend: BluetoothDeviceBackend) async throws {
    let refresh = try #require(backend.scheduledRefresh, "No automatic refresh was scheduled")
    await refresh.value
  }

  private func stopAndDrain(
    backend: BluetoothDeviceBackend,
    transport: BluetoothFixtureTransport,
    clock: DeviceBackendTestClock,
    callerTasks: [Task<Void, any Error>] = [],
    additionalConnectionTasks: [Task<Void, Never>] = [],
    additionalRefreshTasks: [Task<Void, Never>] = [],
    additionalErrorClearTasks: [Task<Void, Never>] = []
  ) async {
    let connectionTasks = backend.currentConnectionTasks() + additionalConnectionTasks
    let refreshTasks = [backend.scheduledRefresh].compactMap { $0 } + additionalRefreshTasks
    let errorClearTasks =
      Array(backend.currentErrorClearTasks().values) + additionalErrorClearTasks
    backend.stop()
    await transport.cancelPending()
    await clock.cancelAllSleeps()
    for task in callerTasks { _ = await task.result }
    for task in connectionTasks { await task.value }
    for task in refreshTasks { await task.value }
    for task in errorClearTasks { await task.value }
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

/// A test-owned, buffered event emitted by production only after its scheduled work has settled.
///
/// The buffer retains a signal that arrives before `wait()`. One deadline task bounds a missing
/// signal: it records a failure and finishes the stream so a missed completion fails the test
/// instead of suspending it.
@MainActor
private final class TestCompletionEvent {
  private let signals: AsyncStream<Void>
  private let sink: AsyncStream<Void>.Continuation

  init() {
    let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    signals = stream.stream
    sink = stream.continuation
  }

  func signal() { sink.yield() }

  func wait() async {
    let signalSink = sink
    let deadline = Task {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      Issue.record("Timed out after 5 seconds waiting for the error-clear completion")
      signalSink.finish()
    }
    // Cancelling the wait finishes the stream, waking next() with nil; the deadline is cancelled
    // and awaited either way, so no task outlives the wait.
    await withTaskCancellationHandler {
      var iterator = signals.makeAsyncIterator()
      await iterator.next()
    } onCancel: {
      deadline.cancel()
      signalSink.finish()
    }
    deadline.cancel()
    await deadline.value
  }
}

private actor BluetoothFixtureTransport: BluetoothDeviceTransport {
  private let notifications: BluetoothNotificationFixture
  private var peers: [BluetoothPeer]
  private var powered: Bool? = true
  private var snapshotError: (any Error)?
  private var pending: [String: [CheckedContinuation<Void, any Error>]] = [:]
  private let connectEntries: AsyncStream<Int>
  private let connectEntryEvents: AsyncStream<Int>.Continuation
  var snapshotCalls = 0
  var connectIDs: [String] = []

  /// Events carry the cumulative count so a wait can target a count reached before it began.
  init(peers: [BluetoothPeer], notifications: BluetoothNotificationFixture) {
    self.peers = peers
    self.notifications = notifications
    let entries = AsyncStream<Int>.makeStream()
    connectEntries = entries.stream
    connectEntryEvents = entries.continuation
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
    connectEntryEvents.yield(connectIDs.count)
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
    connectEntryEvents.finish()
    let continuations = pending.values.flatMap { $0 }
    pending.removeAll()
    for continuation in continuations { continuation.resume(throwing: CancellationError()) }
  }

  func waitForConnectEntry(_ count: Int) async throws {
    do {
      _ = try await waitForStreamValue(
        in: connectEntries, finishing: connectEntryEvents,
        waitedFor: "Bluetooth connect entry count \(count)", matches: { $0 >= count })
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
