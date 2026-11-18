// No-render contracts for AutoEQ profile selection, fallback labeling, and catalog bindings.
import FineTuneDomain
import Foundation
import Testing

@testable import FineTune

@Suite("Presentation contract: mixer AutoEQ profile bindings")
@MainActor
struct MixerProfileContractTests {
  @Test("Selecting an AutoEQ profile targets one device and enables the new selection")
  func profileSelectionKeepsDeviceIdentity() {
    let source = MixerProfileTestSource()
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    bindings.choose(
      MixerProfileChoice(id: "catalog-profile", name: "Headphones", detail: "Measured"))
    #expect(source.lastDeviceUID == "headphones-a")
    #expect(source.lastSelection == AutoEQSelection(profileID: "catalog-profile", isEnabled: true))
    bindings.clear()
    #expect(source.lastDeviceUID == "headphones-a")
    #expect(source.lastSelection == nil)
  }

  @Test("A missing profile remains named and enabling it preserves its desired identity")
  func missingProfileIsNotReplacedByFlat() {
    let source = MixerProfileTestSource()
    source.snapshot.selection = AutoEQSelection(profileID: "offline-profile", isEnabled: false)
    source.snapshot.isMissing = true
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    #expect(bindings.selectionLabel.contains("offline-profile"))
    #expect(!bindings.enabled.wrappedValue)
    bindings.enabled.wrappedValue = true
    #expect(source.lastSelection == AutoEQSelection(profileID: "offline-profile", isEnabled: true))
    #expect(source.snapshot.isMissing)
  }

  @Test("Favorite filtering is requested from the real catalog before its result limit")
  func profileQueryForwardsFavoriteConstraint() {
    let source = MixerProfileTestSource()
    let results = source.interface.search("specific headphones", true)
    #expect(source.lastQuery == "specific headphones")
    #expect(source.lastFavoritesOnly == true)
    #expect(results.entries.map(\.id) == ["catalog-profile"])
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    bindings.toggleFavorite("catalog-profile")
    bindings.preampEnabled.wrappedValue = false
    #expect(source.events == ["favorite:catalog-profile:true", "preamp:false"])
    #expect(source.snapshot.preampEnabled)
  }

  @Test("Explicit import retains the originating device and user-selected file URL")
  func profileImportRetainsOrigin() {
    let source = MixerProfileTestSource()
    let bindings = MixerProfileBindings(deviceUID: "headphones-b", interface: source.interface)
    let url = URL(fileURLWithPath: "/temporary-unit-fixture/ParametricEQ.txt")
    bindings.importFile(url)
    #expect(source.lastDeviceUID == "headphones-b")
    #expect(source.lastImportURL == url)
    #expect(source.lastImportName == "ParametricEQ")
  }
}
