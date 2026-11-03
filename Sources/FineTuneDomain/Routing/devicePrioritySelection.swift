/// UID-only priority policy. Discovery owns availability/liveness and preserves its stable ordering.
public enum DevicePrioritySelection {
  public static func highestPriority(availableUIDs: [String], priorityOrder: [String]) -> String? {
    let connected = Set(availableUIDs)
    return priorityOrder.first(where: connected.contains) ?? availableUIDs.first
  }
}
