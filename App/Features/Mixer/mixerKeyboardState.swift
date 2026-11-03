import Foundation

/// Only transient focus and number-entry state. Audio interpretation stays in Control/Domain.
@MainActor
enum MixerKeyboardInput: Equatable {
  case up, down
  case left(shift: Bool)
  case right(shift: Bool)
  case activate, space, mute, deviceTab
  case digit(Int)
  case delete, cancel
}

@MainActor
enum MixerKeyboardEffect: Equatable {
  case none, close, switchDeviceTab
  case adjust(PopupKeyboardNavModel.RowID, isUp: Bool, shift: Bool)
  case toggleMute(PopupKeyboardNavModel.RowID)
  case activate(PopupKeyboardNavModel.RowID)
  case setPercentage(PopupKeyboardNavModel.RowID, Int)
}

@MainActor
struct MixerKeyboardState {
  var selectedRow: PopupKeyboardNavModel.RowID?
  private(set) var isEngaged = false
  private(set) var percentageDraft: String?

  mutating func process(
    _ input: MixerKeyboardInput, navigation: PopupKeyboardNavModel, defaultOutputUID: String?
  ) -> MixerKeyboardEffect {
    if case .digit(let value) = input { precondition((0...9).contains(value)) }
    if let draft = percentageDraft {
      switch input {
      case .cancel: percentageDraft = nil
      case .delete:
        percentageDraft = draft.count > 1 ? String(draft.dropLast()) : nil
      case .digit(let digit):
        if draft.count < 4 { percentageDraft = draft + String(digit) }
      case .activate:
        // The buffer is constructed exclusively from at most four validated ASCII digits.
        let percentage = Int(draft)!
        percentageDraft = nil
        if let selectedRow { return .setPercentage(selectedRow, min(100, percentage)) }
      default: break
      }
      return .none
    }
    if input == .cancel { return .close }
    let waking = !isEngaged || selectedRow == nil
    if waking {
      isEngaged = true
      selectedRow = navigation.defaultFocus(defaultOutputUID: defaultOutputUID)
    }
    switch input {
    case .up:
      if !waking, let previous = navigation.previous(before: selectedRow) { selectedRow = previous }
      return .none
    case .down:
      if !waking, let next = navigation.next(after: selectedRow) { selectedRow = next }
      return .none
    default: break
    }
    guard let selectedRow else { return .none }
    switch input {
    case .left(let shift): return .adjust(selectedRow, isUp: false, shift: shift)
    case .right(let shift): return .adjust(selectedRow, isUp: true, shift: shift)
    case .mute: return .toggleMute(selectedRow)
    case .activate, .space: return .activate(selectedRow)
    case .deviceTab:
      if case .device = selectedRow { return .switchDeviceTab }
    case .digit(let digit): percentageDraft = String(digit)
    default: break
    }
    return .none
  }
}
