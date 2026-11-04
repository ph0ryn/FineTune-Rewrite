import Foundation
import Observation

public enum BluetoothConnectionPhase: Equatable, Sendable {
  case idle, connecting, basebandConnected, failed
}

/// Paired Bluetooth discovery and connection progress. Audio-device/routing observation stays separate.
@MainActor @Observable
public final class BluetoothDeviceBackend {
  public private(set) var isRunning = false
  public private(set) var isPoweredOn: Bool?
  public private(set) var connectionPhases: [String: BluetoothConnectionPhase] = [:]
  public private(set) var connectionErrors: [String: String] = [:]
  public private(set) var lastError: (any Error)?
  private var knownPeers: [String: BluetoothPeer] = [:]
  private let transport: any BluetoothDeviceTransport
  private let clock: DeviceBackendClock
  @ObservationIgnored private var observation: DevicePropertyObservation?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var attempts: [String: BluetoothConnectionAttempt] = [:]
  @ObservationIgnored private var errorClearTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var errorTokens: [String: UUID] = [:]
  @ObservationIgnored private var lastErrorDeviceID: String?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var refreshGeneration: UInt64 = 0

  public init(transport: any BluetoothDeviceTransport, clock: DeviceBackendClock) {
    self.transport = transport
    self.clock = clock
  }

  public var pairedDevices: [BluetoothPeer] {
    guard isRunning, isPoweredOn == true else { return [] }
    return knownPeers.values.filter {
      $0.isAudioDevice && (!$0.isConnected || connectionPhases[$0.id] == .connecting)
    }.sorted {
      let order = $0.name.localizedCaseInsensitiveCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    generation &+= 1
    let epoch = generation
    observation = transport.observePowerChanges { [weak self] in
      guard let self, self.isRunning, self.generation == epoch else { return }
      self.scheduleRefresh()
    }
    scheduleRefresh()
  }

  public func stop() {
    isRunning = false
    generation &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    observation?.cancel()
    observation = nil
    for (id, attempt) in attempts {
      finish(id: id, token: attempt.token, result: .failure(CancellationError()))
    }
    for task in errorClearTasks.values { task.cancel() }
    errorClearTasks.removeAll()
    errorTokens.removeAll()
    connectionPhases.removeAll()
    connectionErrors.removeAll()
    if lastErrorDeviceID != nil {
      lastError = nil
      lastErrorDeviceID = nil
    }
  }

  isolated deinit {
    observation?.cancel()
    refreshTask?.cancel()
    for task in errorClearTasks.values { task.cancel() }
    for attempt in attempts.values {
      attempt.operation?.cancel()
      attempt.timeout?.cancel()
      for waiter in attempt.waiters { waiter.resume(throwing: CancellationError()) }
    }
  }

  public func refresh() async {
    guard isRunning else { return }
    refreshGeneration &+= 1
    let ticket = refreshGeneration
    let epoch = generation
    await refresh(ticket: ticket, epoch: epoch)
  }

  private func refresh(ticket: UInt64, epoch: UInt64) async {
    guard isRunning, generation == epoch, refreshGeneration == ticket else { return }
    do {
      let snapshot = try await transport.snapshot()
      try Task.checkCancellation()
      guard isRunning, generation == epoch, refreshGeneration == ticket else { return }
      isPoweredOn = snapshot.isPoweredOn
      knownPeers = Dictionary(uniqueKeysWithValues: snapshot.peers.map { ($0.id, $0) })
      if lastErrorDeviceID == nil { lastError = nil }
      for (id, attempt) in attempts {
        if snapshot.isPoweredOn != true || knownPeers[id] == nil {
          finish(
            id: id, token: attempt.token,
            result: .failure(
              DeviceBackendError.operationFailed("The Bluetooth device is no longer available.")))
        }
      }
      for peer in snapshot.peers where attempts[peer.id] == nil {
        if peer.isConnected {
          connectionPhases[peer.id] = .basebandConnected
          clearError(for: peer.id)
        } else if connectionPhases[peer.id] == .basebandConnected {
          connectionPhases[peer.id] = .idle
        }
      }
    } catch is CancellationError {
      return
    } catch {
      guard isRunning, generation == epoch, refreshGeneration == ticket else { return }
      isPoweredOn = nil
      knownPeers.removeAll()
      for (id, attempt) in attempts {
        finish(id: id, token: attempt.token, result: .failure(error))
      }
      lastError = error
      lastErrorDeviceID = nil
    }
  }

  public func connect(id: String) async throws {
    try Task.checkCancellation()
    guard isRunning else { throw CancellationError() }
    guard isPoweredOn == true else {
      let error = DeviceBackendError.operationFailed(
        "Turn on Bluetooth before connecting a device.")
      publishConnectionError(error, id: id, token: UUID())
      throw error
    }
    guard let peer = knownPeers[id], peer.isAudioDevice else {
      let error = DeviceBackendError.unavailableDevice(id)
      publishConnectionError(error, id: id, token: UUID())
      throw error
    }
    if peer.isConnected { return }
    let token = attempts[id]?.token ?? UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let attempt = attempts[id] {
          attempt.waiters.append(continuation)
          return
        }
        clearError(for: id)
        let attempt = BluetoothConnectionAttempt(token: token, continuation: continuation)
        attempts[id] = attempt
        connectionPhases[id] = .connecting
        let transport = transport
        attempt.operation = Task { [weak self] in
          do {
            try await transport.connect(id: id)
            self?.finish(id: id, token: token, result: .success(()))
          } catch {
            self?.finish(id: id, token: token, result: .failure(error))
          }
        }
        let clock = clock
        attempt.timeout = Task { [weak self] in
          do {
            try await clock.sleep(.seconds(12))
            try Task.checkCancellation()
            self?.finish(
              id: id, token: token,
              result: .failure(
                DeviceBackendError.operationFailed(
                  "The Bluetooth connection timed out. It may still complete.")))
          } catch is CancellationError {
            return
          } catch {
            self?.finish(id: id, token: token, result: .failure(error))
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finish(id: id, token: token, result: .failure(CancellationError()))
      }
    }
  }

  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshGeneration &+= 1
    let ticket = refreshGeneration
    let epoch = generation
    // Stamp admission before enqueueing, so an older startup task cannot supersede an explicit refresh.
    refreshTask = Task { [weak self] in await self?.refresh(ticket: ticket, epoch: epoch) }
  }

  private func finish(id: String, token: UUID, result: Result<Void, any Error>) {
    guard let attempt = attempts[id], attempt.token == token else { return }
    attempts.removeValue(forKey: id)
    attempt.operation?.cancel()
    attempt.timeout?.cancel()
    switch result {
    case .success:
      connectionPhases[id] = .basebandConnected
      clearError(for: id)
      if let peer = knownPeers[id] {
        // openConnection's noErr establishes baseband only; no HAL UID is invented from this address.
        knownPeers[id] = BluetoothPeer(
          id: peer.id, name: peer.name, isAudioDevice: peer.isAudioDevice, isConnected: true)
      }
    case .failure(let error) where error is CancellationError:
      connectionPhases[id] = .idle
    case .failure(let error):
      publishConnectionError(error, id: id, token: token)
    }
    for waiter in attempt.waiters { waiter.resume(with: result) }
  }

  private func publishConnectionError(_ error: any Error, id: String, token: UUID) {
    connectionPhases[id] = .failed
    connectionErrors[id] = error.localizedDescription
    lastError = error
    lastErrorDeviceID = id
    scheduleErrorClear(for: id, token: token)
  }

  private func clearError(for id: String) {
    errorClearTasks.removeValue(forKey: id)?.cancel()
    errorTokens.removeValue(forKey: id)
    connectionErrors.removeValue(forKey: id)
    if lastErrorDeviceID == id {
      lastError = nil
      lastErrorDeviceID = nil
    }
  }

  private func scheduleErrorClear(for id: String, token: UUID) {
    errorClearTasks.removeValue(forKey: id)?.cancel()
    errorTokens[id] = token
    let clock = clock
    errorClearTasks[id] = Task { [weak self] in
      do {
        try await clock.sleep(.seconds(4))
        try Task.checkCancellation()
        guard let self, self.errorTokens[id] == token else { return }
        self.clearError(for: id)
        if self.connectionPhases[id] == .failed { self.connectionPhases[id] = .idle }
      } catch is CancellationError {
        return
      } catch {
        self?.lastError = error
        self?.lastErrorDeviceID = nil
      }
    }
  }
}

@MainActor
private final class BluetoothConnectionAttempt {
  let token: UUID
  var waiters: [CheckedContinuation<Void, any Error>]
  var operation: Task<Void, Never>?
  var timeout: Task<Void, Never>?

  init(token: UUID, continuation: CheckedContinuation<Void, any Error>) {
    self.token = token
    waiters = [continuation]
  }
}
