// Independently authored coverage for the fixed compatibility vocabulary.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import Testing

@testable import FineTune

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
