import Foundation
import IOBluetooth

public struct BluetoothPeer: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let isAudioDevice: Bool
  /// A Bluetooth baseband observation, not proof of a usable CoreAudio route.
  public let isConnected: Bool

  public init(id: String, name: String, isAudioDevice: Bool, isConnected: Bool) {
    self.id = id
    self.name = name
    self.isAudioDevice = isAudioDevice
    self.isConnected = isConnected
  }
}

public struct BluetoothTransportSnapshot: Equatable, Sendable {
  public let isPoweredOn: Bool?
  public let peers: [BluetoothPeer]

  public init(isPoweredOn: Bool?, peers: [BluetoothPeer]) {
    self.isPoweredOn = isPoweredOn
    self.peers = peers
  }
}

public protocol BluetoothDeviceTransport: Sendable {
  func snapshot() async throws -> BluetoothTransportSnapshot
  func connect(id: String) async throws
  @MainActor
  func observePowerChanges(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation
}

/// All IOBluetooth objects and synchronous IPC stay on this dedicated serial queue.
public final class SystemBluetoothDeviceTransport: BluetoothDeviceTransport, Sendable {
  private let queue = DispatchQueue(label: "com.finetune-rewrite.bluetooth", qos: .utility)

  public init() {}

  public func snapshot() async throws -> BluetoothTransportSnapshot {
    try await execute {
      guard let controller = IOBluetoothHostController.default() else {
        throw DeviceBackendError.unsupported("Bluetooth")
      }
      let state = controller.powerState
      let powered: Bool? =
        state == kBluetoothHCIPowerStateON
        ? true
        : state == kBluetoothHCIPowerStateOFF ? false : nil
      guard powered == true else {
        return BluetoothTransportSnapshot(isPoweredOn: powered, peers: [])
      }
      // The SDK explicitly documents nil for no paired devices; it is not a fabricated failure value.
      let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
      let peers = try devices.compactMap { device -> BluetoothPeer? in
        guard let id = device.addressString, !id.isEmpty else { return nil }
        return BluetoothPeer(
          id: id, name: device.name ?? id,
          isAudioDevice: try Self.isAudioDevice(device), isConnected: device.isConnected())
      }
      return BluetoothTransportSnapshot(isPoweredOn: true, peers: peers)
    }
  }

  public func connect(id: String) async throws {
    try await execute {
      guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
        throw DeviceBackendError.operationFailed("Turn on Bluetooth before connecting a device.")
      }
      let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
      guard let device = paired.first(where: { $0.addressString == id }), device.isPaired(),
        try Self.isAudioDevice(device)
      else { throw DeviceBackendError.unavailableDevice(id) }
      if device.isConnected() { return }
      let status = device.openConnection()
      guard status == kIOReturnSuccess else { throw DeviceBackendError.osStatus(status) }
    }
  }

  @MainActor
  public func observePowerChanges(
    _ onChange: @escaping @MainActor @Sendable () -> Void
  ) -> DevicePropertyObservation {
    let center = NotificationCenter.default
    let tokens = [
      Notification.Name.IOBluetoothHostControllerPoweredOn,
      Notification.Name.IOBluetoothHostControllerPoweredOff,
    ].map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        Task { @MainActor in onChange() }
      }
    }
    return DevicePropertyObservation {
      for token in tokens { center.removeObserver(token) }
    }
  }

  private static func isAudioDevice(_ device: IOBluetoothDevice) throws -> Bool {
    guard let sink = IOBluetoothSDPUUID(uuid16: 0x110B),
      let handsFree = IOBluetoothSDPUUID(uuid16: 0x111E)
    else { throw DeviceBackendError.operationFailed("Unable to read Bluetooth audio services.") }
    return device.getServiceRecord(for: sink) != nil
      || device.getServiceRecord(for: handsFree) != nil
  }

  private func execute<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    let cancellation = BluetoothIOCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            try cancellation.check()
            let value = try operation()
            // An already-issued synchronous call is not abortable; never publish its stale result.
            try cancellation.check()
            continuation.resume(returning: value)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

private final class BluetoothIOCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    isCancelled = true
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    if isCancelled { throw CancellationError() }
  }
}
