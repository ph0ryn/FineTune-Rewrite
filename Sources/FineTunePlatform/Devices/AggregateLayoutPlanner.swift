/// An OS preparation plan; this does not create aggregates or claim that audio is running.
public struct AggregateLayoutPlan: Equatable, Sendable {
  public let subDeviceUIDs: [String]
  public let isStacked: Bool
  public let clockDeviceUID: String
}

public enum AggregateLayoutPlanner {
  public static func plan(
    outputUIDs: [String], expand: (String) -> [String]?, outputStreamCount: (String) -> Int
  ) -> AggregateLayoutPlan {
    precondition(!outputUIDs.isEmpty, "An aggregate requires at least one output.")
    var flattened = false
    var seen: Set<String> = []
    let devices = outputUIDs.flatMap { uid -> [String] in
      guard let children = expand(uid), !children.isEmpty else { return [uid] }
      flattened = true
      return children
    }.filter { seen.insert($0).inserted }
    let preservesChannels =
      flattened && outputUIDs.count == 1 && devices.count == 1 && outputStreamCount(devices[0]) == 1
    return AggregateLayoutPlan(
      subDeviceUIDs: devices, isStacked: !preservesChannels, clockDeviceUID: devices[0]
    )
  }

  /// Only trailing tap inputs are used. An unknown output count must never disable every input.
  public static func inputStreamUsageFlags(inputCount: Int, outputCount: Int) -> [UInt32]? {
    guard inputCount > 0, outputCount > 0, inputCount > outputCount else { return nil }
    return (0..<inputCount).map { $0 < inputCount - outputCount ? 0 : 1 }
  }
}
