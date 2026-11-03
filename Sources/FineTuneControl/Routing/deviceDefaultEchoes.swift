// SPDX-License-Identifier: GPL-3.0-only
// This entire file is covered by GPL-3.0-only as a derived adaptation.
// Derived GPL-covered adaptation of ronitsingh10/FineTune Audio/Engine/EchoTracker.swift:4–73.
// Pinned revision 2285279d36d3f8115c1c2d4aecd904f1bdf96a51; see the upstream GPLv3 LICENSE.
// Per-UID token acknowledgement/expiry semantics are adapted, not claimed as an ideas-only rewrite.

@MainActor
final class DeviceDefaultEchoes {
  private struct Entry {
    let uid: String
    let task: Task<Void, Never>
  }
  private let sleep: @MainActor (Duration) async throws -> Void
  private var nextToken: UInt64 = 0
  private var entries: [UInt64: Entry] = [:]
  var onTimeout: (@MainActor (String) -> Void)?
  var onFailure: (@MainActor (any Error) -> Void)?
  var hasPending: Bool { !entries.isEmpty }

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
      self.onTimeout?(entry.uid)
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
