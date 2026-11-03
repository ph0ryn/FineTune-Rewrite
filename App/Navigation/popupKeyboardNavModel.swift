import FineTunePlatform
import Observation

/// Ordered focus traversal shared by popup rows. It never wraps at either end.
@MainActor @Observable
final class PopupKeyboardNavModel {
  enum RowID: Hashable {
    case device(uid: String)
    case app(persistenceID: String)
  }

  private(set) var orderedRowIDs: [RowID] = []

  func syncOrder(
    activeDevices: [AudioDevice], appPersistenceIDs: [String], isEditingPriority: Bool
  ) {
    orderedRowIDs =
      isEditingPriority
      ? []
      : activeDevices.map { .device(uid: $0.uid) }
        + appPersistenceIDs.map { .app(persistenceID: $0) }
  }

  func next(after current: RowID?) -> RowID? {
    guard let current, let index = orderedRowIDs.firstIndex(of: current) else {
      return orderedRowIDs.first
    }
    let following = index + 1
    return orderedRowIDs.indices.contains(following) ? orderedRowIDs[following] : nil
  }

  func previous(before current: RowID?) -> RowID? {
    guard let current, let index = orderedRowIDs.firstIndex(of: current), index > 0 else {
      return nil
    }
    return orderedRowIDs[index - 1]
  }

  func defaultFocus(defaultOutputUID: String?) -> RowID? {
    if let defaultOutputUID, orderedRowIDs.contains(.device(uid: defaultOutputUID)) {
      return .device(uid: defaultOutputUID)
    }
    return orderedRowIDs.first
  }
}
