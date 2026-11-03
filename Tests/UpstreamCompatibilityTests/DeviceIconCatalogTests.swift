// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune, FineTuneTests/DeviceIconCatalogTests.swift
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
// Adaptation: Pure symbol selection moved from Core Audio ID extension to App DeviceIconSymbol; inputs/expectations preserved.

// FineTuneTests/DeviceIconCatalogTests.swift

import AppKit
import AudioToolbox
import Testing

@testable import FineTune

@Suite("DeviceIconCatalog")
struct DeviceIconCatalogTests {

  @Test("No duplicate symbols across the catalog")
  func noDuplicates() {
    let symbols = DeviceIconCatalog.allEntries.map(\.symbol)
    #expect(Set(symbols).count == symbols.count)
  }

  @Test("Every catalog symbol resolves to a real SF Symbol")
  func allSymbolsResolve() {
    for entry in DeviceIconCatalog.allEntries {
      #expect(
        NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) != nil,
        "unresolvable symbol: \(entry.symbol)"
      )
    }
  }

  @Test("Every entry carries at least one keyword")
  func keywordsPresent() {
    for entry in DeviceIconCatalog.allEntries {
      #expect(!entry.keywords.isEmpty, "no keywords: \(entry.symbol)")
    }
  }

  @Test("entry(for:) round-trips every catalog symbol and misses cleanly")
  func entryLookupRoundTrips() {
    for entry in DeviceIconCatalog.allEntries {
      #expect(DeviceIconCatalog.entry(for: entry.symbol) == entry)
    }
    #expect(DeviceIconCatalog.entry(for: "not.a.catalog.symbol") == nil)
  }

  @Test("Search matches symbol names and keywords, case-insensitively")
  func searchMatching() {
    let byName = DeviceIconCatalog.matching("AIRPODS").map(\.symbol)
    #expect(byName.contains("airpodspro"))

    let byKeyword = DeviceIconCatalog.matching("cans").map(\.symbol)
    #expect(byKeyword.contains("headphones"))

    let byMultiWordKeyword = DeviceIconCatalog.matching("apple tv").map(\.symbol)
    #expect(byMultiWordKeyword.contains("appletv.fill"))

    #expect(DeviceIconCatalog.matching("zzzz-no-match").isEmpty)
  }

  @Test("Empty and whitespace-only queries return the full catalog")
  func emptyQueryReturnsAll() {
    #expect(DeviceIconCatalog.matching("").count == DeviceIconCatalog.allEntries.count)
    #expect(DeviceIconCatalog.matching("   ").count == DeviceIconCatalog.allEntries.count)
  }

  @Test(
    "Suggestions lead with the automatic guess and never duplicate",
    arguments: [
      TransportType.builtIn, .usb, .bluetooth, .bluetoothLE, .airPlay,
      .virtual, .thunderbolt, .hdmi, .displayPort, .aggregate, .unknown,
    ])
  func suggestionsPerTransport(transport: TransportType) {
    let suggested = DeviceIconCatalog.suggested(forName: "Some Device", transport: transport)
    #expect(!suggested.isEmpty)
    #expect(
      suggested.first == DeviceIconSymbol.iconSymbol(forName: "Some Device", transport: transport))
    #expect(Set(suggested).count == suggested.count)
    for symbol in suggested {
      #expect(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
        "unresolvable suggestion: \(symbol)")
    }
  }

  // iconSymbol() can lead with symbols absent from the catalog (e.g. "homepod",
  // "appletv"), so these name/transport pairs pin that those still resolve.
  @Test(
    "Suggestions for recognized device names lead with the automatic guess and resolve",
    arguments: [
      ("HomePod mini", TransportType.airPlay),
      ("Apple TV 4K", .airPlay),
      ("Mac Studio Speakers", .builtIn),
      ("Beats Studio Pro", .bluetooth),
      ("MacBook Pro Speakers", .builtIn),
    ])
  func suggestionsPerName(name: String, transport: TransportType) {
    let suggested = DeviceIconCatalog.suggested(forName: name, transport: transport)
    #expect(!suggested.isEmpty)
    #expect(suggested.first == DeviceIconSymbol.iconSymbol(forName: name, transport: transport))
    #expect(Set(suggested).count == suggested.count)
    for symbol in suggested {
      #expect(
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
        "unresolvable suggestion: \(symbol)")
    }
  }

  @Test("Name-derived suggestion wins over transport family")
  func nameDerivedSuggestion() {
    let suggested = DeviceIconCatalog.suggested(forName: "AirPods Pro", transport: .bluetooth)
    #expect(suggested.first == "airpodspro")
  }
}

// Additional coverage prevents an implementation with a reduced catalog from passing the generic invariants.
@Suite("DeviceIconCatalog — fixed compatibility vocabulary")
struct DeviceIconCatalogVocabularyTests {
  @Test("All five catalog groups retain their full choice counts")
  func categoryCoverage() {
    #expect(
      DeviceIconCatalog.categories.map(\.name) == [
        "Headphones & Earbuds", "Speakers", "Computers & Displays", "Microphones",
        "Connectors & Other",
      ])
    #expect(DeviceIconCatalog.categories.map { $0.entries.count } == [21, 18, 15, 8, 23])
    #expect(DeviceIconCatalog.allEntries.count == 85)
  }
}
