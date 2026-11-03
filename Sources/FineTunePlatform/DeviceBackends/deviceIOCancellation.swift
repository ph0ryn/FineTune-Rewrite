import Foundation

/// Shared cooperative admission/result guard for blocking SDK queues; it cannot undo issued IPC.
final class DeviceIOCancellation: @unchecked Sendable {
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
