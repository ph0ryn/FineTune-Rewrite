import Observation

/// Shared timer mechanics only; input/output controllers own their different selection policies.
@Observable @MainActor
final class DeviceAutoSwitchGrace {
  private let sleep: @MainActor (Duration) async throws -> Void
  private var generation: UInt64 = 0
  @ObservationIgnored private var task: Task<Void, Never>?
  var onFailure: (@MainActor (any Error) -> Void)?
  private(set) var uid: String?
  private(set) var duration: Duration?

  init(sleep: @escaping @MainActor (Duration) async throws -> Void) { self.sleep = sleep }
  isolated deinit { task?.cancel() }

  func start(uid: String, bluetooth: Bool) {
    cancel()
    self.uid = uid
    // Pinned upstream uses five seconds for Bluetooth/BLE and two for every other/unknown transport.
    let duration = Duration.seconds(bluetooth ? 5 : 2)
    self.duration = duration
    let current = generation
    let delay = sleep
    task = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        try await delay(duration)
      } catch is CancellationError { return } catch {
        guard let self, self.generation == current else { return }
        self.onFailure?(error)
        return
      }
      guard let self, !Task.isCancelled, self.generation == current else { return }
      self.uid = nil
      self.duration = nil
      self.task = nil
    }
  }

  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    uid = nil
    duration = nil
  }
}
