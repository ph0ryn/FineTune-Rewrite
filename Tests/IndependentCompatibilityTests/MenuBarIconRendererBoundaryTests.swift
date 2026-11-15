// Independently authored coverage for the production renderer boundary.
// Split from the GPL-derived upstream suite per the manifest D record; no upstream body is copied.

import AppKit
import Testing

@testable import FineTune

@Suite("MenuBarIconImage — production renderer boundary")
@MainActor
struct MenuBarIconRendererBoundaryTests {
  @Test("Unknown symbols and absent named assets remain explicit missing images")
  func missingImagesRemainNil() {
    #expect(MenuBarIconImage.systemSymbol("not.a.real.symbol.zzz").nsImage() == nil)
    #expect(MenuBarIconImage.asset("FineTuneRewriteMissingAssetFixture").nsImage() == nil)
  }

  @Test("A caller-provided accessibility description survives normalization")
  func customAccessibilityDescription() throws {
    let image = try #require(
      MenuBarIconImage.systemSymbol("headphones").nsImage(accessibilityDescription: "Output device")
    )
    #expect(image.accessibilityDescription == "Output device")
    #expect(image.size == NSSize(width: 22, height: 18))
    #expect(image.isTemplate)
  }
}
