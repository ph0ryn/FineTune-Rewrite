import FineTuneDomain

/// A canonical application from the single platform grouper. No HAL object enters Control.
public struct AudioApplicationDescriptor: Equatable, Sendable {
  public let identifier: String
  public let processID: Int32
  public let processRevision: UInt64
  public let displayName: String
  public let bundleID: String?

  public init(
    identifier: String, processID: Int32, processRevision: UInt64, displayName: String,
    bundleID: String?
  ) {
    self.identifier = identifier
    self.processID = processID
    self.processRevision = processRevision
    self.displayName = displayName
    self.bundleID = bundleID
  }
}

/// UID-local processing values, distinct from the output's raw hardware/DDC scalar.
public struct AudioOutputDescriptor: Equatable, Sendable {
  public let uid: String
  public let bindingRevision: UInt64
  public let supportsAutoEQ: Bool
  public let processingGain: Float
  public let volume: Float?
  public let isMuted: Bool?

  public init(
    uid: String, bindingRevision: UInt64, supportsAutoEQ: Bool, processingGain: Float,
    volume: Float?, isMuted: Bool?
  ) {
    self.uid = uid
    self.bindingRevision = bindingRevision
    self.supportsAutoEQ = supportsAutoEQ
    self.processingGain = processingGain
    self.volume = volume
    self.isMuted = isMuted
  }
}

struct AudioRouteWorkID: Hashable {
  let identifier: String
  let generation: UInt64
}

struct AudioRoutePlan: Equatable {
  let processRevision: UInt64
  let sessionID: UInt64
  let outputs: [AudioOutputDescriptor]

  /// Level changes never create an OS graph or reset independent per-output histories.
  func hasSameBindings(as other: Self) -> Bool {
    processRevision == other.processRevision && sessionID == other.sessionID
      && outputs.map { ($0.uid, $0.bindingRevision) }.elementsEqual(
        other.outputs.map { ($0.uid, $0.bindingRevision) }, by: ==)
  }
}
