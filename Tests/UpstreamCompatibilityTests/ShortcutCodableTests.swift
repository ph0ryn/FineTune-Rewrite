// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTuneTests/ShortcutCodableTests.swift at
// upstream 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.

// FineTuneTests/ShortcutCodableTests.swift
import Testing
import Foundation
import KeyboardShortcuts
@testable import FineTune

@Suite("ShortcutCodable")
struct ShortcutCodableTests {
    @Test("round-trips through JSON")
    func roundTrip() throws {
        let original = ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ShortcutCodable.self, from: data)
        #expect(decoded == original)
    }

    @Test("inverse of KeyboardShortcuts.Shortcut")
    @MainActor
    func inverse() {
        let shortcut = KeyboardShortcuts.Shortcut(carbonKeyCode: 9, carbonModifiers: 0x100)
        let codable = ShortcutCodable.from(shortcut)
        let recovered = codable.keyboardShortcut
        #expect(recovered.carbonKeyCode == shortcut.carbonKeyCode)
        #expect(recovered.carbonModifiers == shortcut.carbonModifiers)
    }
}
