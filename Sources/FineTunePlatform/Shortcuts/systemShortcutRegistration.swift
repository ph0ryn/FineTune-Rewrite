import FineTuneControl
import FineTuneDomain
import KeyboardShortcuts

/// The sole adapter that writes the library's preferences and registers Carbon hotkeys.
@MainActor
public final class SystemShortcutRegistration: ShortcutRegistering {
  public init() {}

  public func shortcut(for identifier: String) -> ShortcutCodable? {
    KeyboardShortcuts.getShortcut(for: .init(identifier)).map(ShortcutCodable.from)
  }

  public func setShortcut(_ shortcut: ShortcutCodable?, for identifier: String) {
    KeyboardShortcuts.setShortcut(shortcut?.keyboardShortcut, for: .init(identifier))
  }

  public func register(
    identifier: String, onKeyDown: @escaping @MainActor () -> Void,
    onKeyUp: @escaping @MainActor () -> Void
  ) {
    let name = KeyboardShortcuts.Name(identifier)
    KeyboardShortcuts.onKeyDown(for: name, action: onKeyDown)
    KeyboardShortcuts.onKeyUp(for: name, action: onKeyUp)
  }

  public func unregister(identifier: String) {
    KeyboardShortcuts.removeHandler(for: .init(identifier))
  }
}
