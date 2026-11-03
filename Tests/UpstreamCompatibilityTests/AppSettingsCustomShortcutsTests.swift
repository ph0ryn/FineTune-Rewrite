// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTuneTests/AppSettingsCustomShortcutsTests.swift at
// upstream 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.

// FineTuneTests/AppSettingsCustomShortcutsTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("AppSettings customShortcuts")
@MainActor
struct AppSettingsCustomShortcutsTests {
    @Test("round-trips a custom shortcut")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.customShortcuts[ShortcutAction.togglePopup.rawValue] =
            ShortcutCodable(keyCode: 9, modifiers: 0x12_0000)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.customShortcuts == settings.customShortcuts)
    }

    @Test("defaults to empty when missing from JSON")
    func defaultsEmpty() throws {
        // legacy JSON without customShortcuts field — every other field also missing,
        // exercising the same decodeIfPresent fallback path used in production.
        let json = """
        { "defaultNewAppVolume": 1.0 }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)

        #expect(decoded.customShortcuts.isEmpty)
    }
}
