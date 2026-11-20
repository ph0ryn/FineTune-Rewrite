@MainActor
final class DeviceDefaultEchoes {
  private struct Entry {
    let uid: String
    let task: Task<Void, Never>
  }
  private let sleep: @MainActor (Duration) async throws -> Void
  private var nextToken: UInt64 = 0
  private var entries: [UInt64: Entry] = [:]
  var onTimeout: (@MainActor (UInt64, String) -> Void)?
  var onFailure: (@MainActor (any Error) -> Void)?

  init(sleep: @escaping @MainActor (Duration) async throws -> Void) { self.sleep = sleep }
  isolated deinit { for entry in entries.values { entry.task.cancel() } }

  /// Reserve before the synchronous writer so reentrant acknowledgements cannot precede registration.
  /// A rejected writer cancels this token; only accepted operations retain their acknowledgement wait.
  func reserve(_ uid: String) -> UInt64 {
    nextToken &+= 1
    let token = nextToken
    let delay = sleep
    let task = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        try await delay(.seconds(2))
      } catch is CancellationError { return } catch {
        guard let self, self.entries.removeValue(forKey: token) != nil else { return }
        self.onFailure?(error)
        return
      }
      guard let self, !Task.isCancelled, let entry = self.entries.removeValue(forKey: token) else {
        return
      }
      self.onTimeout?(token, entry.uid)
    }
    entries[token] = Entry(uid: uid, task: task)
    return token
  }

  func consume(_ uid: String) -> Bool {
    guard let token = entries.keys.filter({ entries[$0]?.uid == uid }).min() else { return false }
    cancel(token)
    return true
  }

  func cancel(_ token: UInt64) { entries.removeValue(forKey: token)?.task.cancel() }
  func cancelAll() {
    for entry in entries.values { entry.task.cancel() }
    entries.removeAll()
  }
}
