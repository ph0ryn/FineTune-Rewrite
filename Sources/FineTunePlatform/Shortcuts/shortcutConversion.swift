import FineTuneDomain
import KeyboardShortcuts

@MainActor
extension ShortcutCodable {
  public static func from(_ shortcut: KeyboardShortcuts.Shortcut) -> Self {
    Self(keyCode: shortcut.carbonKeyCode, modifiers: UInt(shortcut.carbonModifiers))
  }

  public var keyboardShortcut: KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: Int(modifiers))
  }
}
