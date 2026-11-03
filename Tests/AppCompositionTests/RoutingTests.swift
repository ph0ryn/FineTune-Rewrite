import FineTuneDomain
import FineTunePlatform
import Testing

@Suite("Routing profile-cache invalidation")
@MainActor
struct ProfileAvailabilityCacheTests {
  @Test("Removing a profile invalidates only that cached ID and permits a later replacement")
  func removesOnlyTheSelectedProfile() {
    let first = AutoEQProfile(
      id: "first", name: "First", source: .imported, preampDB: -3, filters: [])
    let other = AutoEQProfile(
      id: "other", name: "Other", source: .bundled, preampDB: -5, filters: [])
    let cache = AutoEQProfileCache(profiles: [first, other])
    cache.remove(id: first.id)
    #expect(cache.profile(for: first.id) == nil)
    #expect(cache.profile(for: other.id) == other)
    cache.remove(id: "absent")
    #expect(cache.profile(for: other.id) == other)
    cache.store(first)
    #expect(cache.profile(for: first.id) == first)
  }
}
