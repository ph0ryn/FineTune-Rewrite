// No-render contract for EQ preset selection: every applied choice must close the picker.
import FineTuneDomain
import Foundation
import Testing

@testable import FineTune

@Suite("Presentation contract: EQ preset selection")
@MainActor
struct MixerEQPresetSelectionTests {
  @Test("Selecting a built-in preset applies it and closes the picker")
  func builtInSelectionClosesPicker() {
    var events: [String] = []
    let selection = MixerEQPresetSelection(
      applyBuiltIn: { events.append("builtin:\($0.rawValue)") },
      applyCurve: { _ in events.append("curve") },
      close: { events.append("close") })

    selection.select(.vocalClarity)

    #expect(events == ["builtin:vocalClarity", "close"])
  }

  @Test("Selecting a saved curve applies it and closes the picker")
  func savedCurveSelectionClosesPicker() {
    var events: [String] = []
    let selection = MixerEQPresetSelection(
      applyBuiltIn: { _ in events.append("builtin") },
      applyCurve: { events.append("curve:\($0.bandGains.count)") },
      close: { events.append("close") })

    selection.select(EQSettings(bandGains: [1, 2, 3]))

    #expect(events == ["curve:10", "close"])
  }
}
