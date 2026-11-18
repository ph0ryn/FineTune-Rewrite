import FineTuneDomain
import Testing

@Suite("Domain: Boost cycle and device priority selection")
struct BoostAndPriorityDomainTests {
  @Test("BoostLevel cycles deterministically and exposes expected multipliers and labels")
  func boostCycleAndLabels() {
    #expect(BoostLevel.allCases == [.x1, .x2, .x3, .x4])
    #expect(BoostLevel.x1.next == .x2)
    #expect(BoostLevel.x2.next == .x3)
    #expect(BoostLevel.x3.next == .x4)
    #expect(BoostLevel.x4.next == .x1)

    #expect(!BoostLevel.x1.isBoosted)
    for boosted in [BoostLevel.x2, .x3, .x4] {
      #expect(boosted.isBoosted)
    }
    #expect(BoostLevel.allCases.map(\.label) == ["1x", "2x", "3x", "4x"])
    #expect(BoostLevel.allCases.map(\.rawValue) == [1, 2, 3, 4])
  }

  @Test("DevicePrioritySelection picks highest connected priority and falls back cleanly")
  func prioritySelectionInvariants() {
    #expect(
      DevicePrioritySelection.highestPriority(availableUIDs: [], priorityOrder: ["A", "B"]) == nil)
    #expect(
      DevicePrioritySelection.highestPriority(
        availableUIDs: ["C", "B"], priorityOrder: ["A", "B", "C"]) == "B")
    #expect(
      DevicePrioritySelection.highestPriority(
        availableUIDs: ["X", "Y"], priorityOrder: ["A", "B"]) == "X")
    #expect(
      DevicePrioritySelection.highestPriority(availableUIDs: ["X", "Y"], priorityOrder: []) == "X")
  }
}
