import FineTunePlatform
import Foundation
import Observation
import Testing

@Suite("Bluetooth device backend")
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
    backend.stop()
  }

  @Test("A failed power read invalidates the previous on or off observation", arguments: [false, true])
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
  func automaticPowerRefresh() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let backend = BluetoothDeviceBackend(transport: transport, clock: .continuous)
    backend.start()
    await waitForPower(backend, powered: true)
    #expect(await transport.snapshotCalls == 1)

    await transport.setPowered(false)
    notifications.callbacks.last?()
    await waitForPower(backend, powered: false)
    await transport.setPowered(nil)
    notifications.callbacks.last?()
    await waitForPower(backend, powered: nil)
    #expect(backend.lastError == nil)
    backend.stop()
  }

  @Test("A failed power observation ends an in-flight request without publishing late SDK success")
  func failedPowerReadDuringConnection() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    let request = Task { try await backend.connect(id: "a") }
    await transport.waitForConnectCount(1)
    await clock.waitForSleepCount(1)

    await transport.setSnapshotFailure(DeviceBackendError.osStatus(-5))
    await backend.refresh()
    #expect(backend.isPoweredOn == nil)
    #expect(backend.connectionPhases["a"] == .failed)
    await transport.complete(id: "a")
    await transport.waitForReturnCount(1)
    await #expect(throws: DeviceBackendError.osStatus(-5)) { try await request.value }
    #expect(backend.connectionPhases["a"] == .failed)
    #expect(backend.isPoweredOn == nil)
    backend.stop()
  }

  @Test("Duplicate requests share one baseband operation and never claim an audio route")
  func duplicateConnect() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    let first = Task { try await backend.connect(id: "a") }
    await transport.waitForConnectCount(1)
    let second = Task { try await backend.connect(id: "a") }
    await clock.waitForSleepCount(1)
    await transport.complete(id: "a")
    try await first.value
    try await second.value
    #expect(await transport.connectIDs == ["a"])
    #expect(backend.connectionPhases["a"] == .basebandConnected)
    backend.stop()
  }

  @Test("A timeout is bounded independently of blocking SDK completion and clears its inline error")
  func timeoutAndLateCompletion() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    let request = Task { try await backend.connect(id: "a") }
    await transport.waitForConnectCount(1)
    await clock.waitForSleepCount(1)
    await clock.advance(by: .seconds(12))
    await #expect(throws: (any Error).self) { try await request.value }
    #expect(backend.connectionPhases["a"] == .failed)
    #expect(backend.connectionErrors["a"] != nil)
    await clock.waitForSleepCount(2)
    await clock.advance(by: .seconds(4))
    await waitForErrorClear(backend, id: "a")
    #expect(backend.connectionPhases["a"] == .idle)
    backend.stop()
    await transport.complete(id: "a")
    await transport.waitForReturnCount(1)
    await Task.yield()
    #expect(backend.connectionPhases.isEmpty)
  }

  @Test("Power-off and unpaired identities cannot open a Bluetooth connection")
  func requestValidation() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Headphones")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    await #expect(throws: (any Error).self) { try await backend.connect(id: "not-paired") }
    await transport.setPowered(false)
    await backend.refresh()
    await #expect(throws: (any Error).self) { try await backend.connect(id: "a") }
    #expect(await transport.connectIDs.isEmpty)
    backend.stop()
  }

  @Test("An SDK failure stays visible when another device connects successfully")
  func independentConnectionFailure() async throws {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(
      peers: [peer("a", "Alpha"), peer("z", "Zulu")], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    let failed = Task { try await backend.connect(id: "a") }
    await transport.waitForConnectCount(1)
    await clock.waitForSleepCount(1)
    await transport.complete(id: "a", error: DeviceBackendError.osStatus(-5))
    await #expect(throws: (any Error).self) { try await failed.value }
    #expect(backend.connectionPhases["a"] == .failed)
    await clock.waitForSleepCount(2)
    let succeeded = Task { try await backend.connect(id: "z") }
    await transport.waitForConnectCount(2)
    await clock.waitForSleepCount(3)
    await transport.complete(id: "z")
    try await succeeded.value
    #expect(backend.connectionErrors["a"] != nil && backend.lastError != nil)
    #expect(backend.connectionPhases["z"] == .basebandConnected)
    backend.stop()
  }

  @Test("Stop removes power observers and rejects their late callbacks")
  func notificationLifetime() async {
    let notifications = BluetoothNotificationFixture()
    let transport = BluetoothFixtureTransport(peers: [], notifications: notifications)
    let clock = DeviceBackendTestClock()
    let backend = BluetoothDeviceBackend(
      transport: transport, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
    backend.start()
    await backend.refresh()
    #expect(notifications.active == 1)
    let callback = notifications.callbacks.first
    backend.stop()
    backend.stop()
    #expect(notifications.active == 0)
    let calls = await transport.snapshotCalls
    callback?()
    await Task.yield()
    #expect(await transport.snapshotCalls == calls)
  }

  private func peer(_ id: String, _ name: String, audio: Bool = true, connected: Bool = false)
    -> BluetoothPeer
  {
    BluetoothPeer(id: id, name: name, isAudioDevice: audio, isConnected: connected)
  }

  private func waitForPower(_ backend: BluetoothDeviceBackend, powered: Bool?) async {
    while backend.isPoweredOn != powered {
      await withCheckedContinuation { continuation in
        withObservationTracking {
          _ = backend.isPoweredOn
        } onChange: {
          continuation.resume()
        }
      }
    }
  }

  private func waitForErrorClear(_ backend: BluetoothDeviceBackend, id: String) async {
    while backend.connectionErrors[id] != nil {
      await withCheckedContinuation { continuation in
        withObservationTracking {
          _ = backend.connectionErrors[id]
        } onChange: {
          continuation.resume()
        }
      }
    }
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
  private var connectBarriers: [(Int, CheckedContinuation<Void, Never>)] = []
  private var returnBarriers: [(Int, CheckedContinuation<Void, Never>)] = []
  private var returned = 0
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
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      pending[id, default: []].append(continuation)
      let ready = connectBarriers.filter { $0.0 <= connectIDs.count }
      connectBarriers.removeAll { $0.0 <= connectIDs.count }
      for barrier in ready { barrier.1.resume() }
    }
    returned += 1
    let ready = returnBarriers.filter { $0.0 <= returned }
    returnBarriers.removeAll { $0.0 <= returned }
    for barrier in ready { barrier.1.resume() }
  }

  func complete(id: String, error: (any Error)? = nil) {
    for continuation in pending.removeValue(forKey: id) ?? [] {
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
  }

  func waitForConnectCount(_ count: Int) async {
    guard connectIDs.count < count else { return }
    await withCheckedContinuation { connectBarriers.append((count, $0)) }
  }

  func waitForReturnCount(_ count: Int) async {
    guard returned < count else { return }
    await withCheckedContinuation { returnBarriers.append((count, $0)) }
  }

  @MainActor
  func observePowerChanges(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation { notifications.observe(onChange) }
}
