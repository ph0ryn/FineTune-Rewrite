import FineTuneDomain

/// Persistence and global key delivery are external operations, not selection or volume policy.
@MainActor
public protocol ShortcutRegistering: AnyObject {
  func shortcut(for identifier: String) -> ShortcutCodable?
  func setShortcut(_ shortcut: ShortcutCodable?, for identifier: String)
  func register(
    identifier: String, onKeyDown: @escaping @MainActor () -> Void,
    onKeyUp: @escaping @MainActor () -> Void)
  func unregister(identifier: String)
}
