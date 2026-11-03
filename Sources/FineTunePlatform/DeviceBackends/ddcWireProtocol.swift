import Foundation

public struct DDCVCPValue: Equatable, Sendable {
  public let current: UInt16
  public let maximum: UInt16

  public init(current: UInt16, maximum: UInt16) {
    self.current = current
    self.maximum = maximum
  }
}

public struct DDCDisplayEDID: Equatable, Sendable {
  public let vendorID: UInt16
  public let productID: UInt16
  public let serialNumber: UInt32

  public init(vendorID: UInt16, productID: UInt16, serialNumber: UInt32) {
    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
  }

  public init(bytes: [UInt8]) throws {
    guard bytes.count == 128,
      Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0]
    else { throw DDCPacketError.invalidResponse }
    guard bytes.reduce(0, &+) == 0 else { throw DDCPacketError.checksumMismatch }
    vendorID = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    productID = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
    serialNumber =
      UInt32(bytes[12]) | UInt32(bytes[13]) << 8
      | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
  }

  /// Fixed-source Apple-Silicon HDMI/DP UID heuristic only, not a public physical-identity guarantee.
  public var encodedUIDPrefix: String {
    let swapped = (productID & 0xFF) << 8 | productID >> 8
    return String(format: "%04x%04x", UInt32(vendorID), UInt32(swapped))
  }
}

enum DDCPacketError: Error, Equatable, LocalizedError {
  case invalidResponse, checksumMismatch, unsupportedVCP

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The display returned an invalid DDC response."
    case .checksumMismatch: "The display's DDC response failed its checksum."
    case .unsupportedVCP: "The display does not support DDC speaker volume."
    }
  }
}

/// Wire-format logic is shared by the real serial transport and synthetic packet tests.
enum DDCPacketCodec {
  static var getVolumeRequest: [UInt8] { packet([0x82, 0x01, 0x62]) }

  static func setVolumeRequest(rawValue: UInt16) -> [UInt8] {
    packet([0x84, 0x03, 0x62, UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)])
  }

  static func parseVolumeReply(_ bytes: [UInt8]) throws -> DDCVCPValue {
    guard bytes.count == 11, bytes[0] == 0x6E, bytes[1] == 0x88, bytes[2] == 0x02 else {
      throw DDCPacketError.invalidResponse
    }
    guard bytes.prefix(10).reduce(0x50, ^) == bytes[10] else {
      throw DDCPacketError.checksumMismatch
    }
    guard bytes[3] == 0 else { throw DDCPacketError.unsupportedVCP }
    guard bytes[4] == 0x62 else { throw DDCPacketError.invalidResponse }
    return DDCVCPValue(
      current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
      maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
  }

  private static func packet(_ bytes: [UInt8]) -> [UInt8] {
    bytes + [bytes.reduce(0x3F, ^)]
  }
}

/// Synchronous, non-Sendable operations: the live owner confines an entire session to one queue.
struct DDCI2COperations {
  let write: (UInt32, UInt32, [UInt8]) throws -> Void
  let read: (UInt32, UInt32, Int) throws -> [UInt8]
  let sleepMilliseconds: (Int) -> Void
}

struct DDCWireSession {
  let io: DDCI2COperations

  func readVolume() throws -> DDCVCPValue {
    try retry {
      try send(DDCPacketCodec.getVolumeRequest)
      io.sleepMilliseconds(50)
      return try DDCPacketCodec.parseVolumeReply(io.read(0x37, 0, 11))
    }
  }

  /// Successful byte submission is not an applied-volume acknowledgement; the caller must read back.
  func writeVolume(rawValue: UInt16) throws {
    try retry { try send(DDCPacketCodec.setVolumeRequest(rawValue: rawValue)) }
  }

  func readEDID() throws -> DDCDisplayEDID {
    try DDCDisplayEDID(bytes: io.read(0x50, 0, 128))
  }

  private func send(_ bytes: [UInt8]) throws {
    var accepted = false
    var lastFailure: any Error = DDCPacketError.invalidResponse
    for _ in 0..<2 {
      io.sleepMilliseconds(10)
      do {
        try io.write(0x37, 0x51, bytes)
        accepted = true
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastFailure = error
      }
    }
    guard accepted else { throw lastFailure }
  }

  private func retry<Value>(_ operation: () throws -> Value) throws -> Value {
    // Four backoffs plus a final attempt preserve the fixed source's five bounded transactions.
    for _ in 0..<4 {
      do { return try operation() } catch is CancellationError {
        throw CancellationError()
      } catch {
        io.sleepMilliseconds(100)
      }
    }
    return try operation()
  }
}
