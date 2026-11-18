import Foundation
import Testing

@testable import FineTunePlatform

@Suite("DDC packet codec, wire protocol and display matching")
struct DDCPacketAndMatchingTests {
  @Test("DDC volume requests preserve the fixed protocol bytes and 16-bit values")
  func requestPackets() {
    #expect(DDCPacketCodec.getVolumeRequest == [0x82, 0x01, 0x62, 0xDE])
    #expect(DDCPacketCodec.setVolumeRequest(rawValue: 100) == [0x84, 0x03, 0x62, 0, 100, 0xBE])
    #expect(DDCPacketCodec.setVolumeRequest(rawValue: 258) == [0x84, 0x03, 0x62, 1, 2, 0xD9])
  }

  @Test("A volume reply validates framing, feature, checksum and unsupported status")
  func replyValidation() throws {
    let valid = volumeReply
    let value = try DDCPacketCodec.parseVolumeReply(valid)
    #expect(value.current == 75 && value.maximum == 100)
    #expect(throws: DDCPacketError.invalidResponse) {
      try DDCPacketCodec.parseVolumeReply(Array(valid.dropLast()))
    }
    var checksum = valid
    checksum[10] ^= 1
    #expect(throws: DDCPacketError.checksumMismatch) {
      try DDCPacketCodec.parseVolumeReply(checksum)
    }
    for (index, changed) in [(0, UInt8(0x51)), (1, 0x80), (2, 0x03), (4, 0x10)] {
      var wrong = valid
      wrong[index] = changed
      wrong[10] = wrong.prefix(10).reduce(0x50, ^)
      #expect(throws: DDCPacketError.invalidResponse) { try DDCPacketCodec.parseVolumeReply(wrong) }
    }
    var unsupported = valid
    unsupported[3] = 1
    unsupported[10] = unsupported.prefix(10).reduce(0x50, ^)
    #expect(throws: DDCPacketError.unsupportedVCP) {
      try DDCPacketCodec.parseVolumeReply(unsupported)
    }
  }

  @Test("The actual wire session sends both cycles and uses the documented read address and delays")
  func wireReadSequence() throws {
    let io = DDCWireFixture(replies: [volumeReply])
    let session = DDCWireSession(io: io.operations)
    #expect(try session.readVolume().current == 75)
    #expect(
      io.writes.map(\.bytes) == [DDCPacketCodec.getVolumeRequest, DDCPacketCodec.getVolumeRequest])
    #expect(io.writes.allSatisfy { $0.chip == 0x37 && $0.address == 0x51 })
    #expect(io.reads == [DDCWireFixture.Read(chip: 0x37, address: 0, count: 11)])
    #expect(io.events == ["sleep10", "write", "sleep10", "write", "sleep50", "read11"])
  }

  @Test("Busy replies retry complete transactions and exhausted writes cannot become success")
  func boundedRetries() throws {
    let busy = [UInt8(0x6E), 0x80] + [UInt8](repeating: 0, count: 9)
    let io = DDCWireFixture(replies: [busy, volumeReply])
    #expect(try DDCWireSession(io: io.operations).readVolume().current == 75)
    #expect(io.writes.count == 4 && io.events.filter { $0 == "sleep100" }.count == 1)
    let failed = DDCWireFixture(replies: [], writeStatuses: [Int32](repeating: -5, count: 10))
    #expect(throws: DeviceBackendError.osStatus(-5)) {
      try DDCWireSession(io: failed.operations).writeVolume(rawValue: 40)
    }
    #expect(failed.writes.count == 10 && failed.reads.isEmpty)
    #expect(failed.events.filter { $0 == "sleep100" }.count == 4)
  }

  @Test(
    "A successful first write cycle is not erased by a failing second cycle, and is not a readback")
  func partialWriteCycle() throws {
    let io = DDCWireFixture(replies: [], writeStatuses: [0, -5])
    try DDCWireSession(io: io.operations).writeVolume(rawValue: 40)
    #expect(io.writes.count == 2 && io.reads.isEmpty)
  }

  @Test("EDID bytes validate header/checksum and decode the original endian/prefix contract")
  func edidValidation() throws {
    var data = [UInt8](repeating: 0, count: 128)
    data.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
    data.replaceSubrange(8..<16, with: [0x12, 0x34, 0x78, 0x56, 4, 3, 2, 1])
    data[127] = 0 &- data.prefix(127).reduce(0, &+)
    let edid = try DDCDisplayEDID(bytes: data)
    #expect(edid.vendorID == 0x1234 && edid.productID == 0x5678 && edid.serialNumber == 0x0102_0304)
    #expect(edid.encodedUIDPrefix == "12347856")
    let io = DDCWireFixture(replies: [data])
    #expect(try DDCWireSession(io: io.operations).readEDID() == edid)
    #expect(io.reads == [DDCWireFixture.Read(chip: 0x50, address: 0, count: 128)])
    data[20] ^= 1
    #expect(throws: DDCPacketError.checksumMismatch) { try DDCDisplayEDID(bytes: data) }
    data[0] = 1
    data[127] = 0 &- data.prefix(127).reduce(0, &+)
    #expect(throws: DDCPacketError.invalidResponse) { try DDCDisplayEDID(bytes: data) }
    #expect(throws: DDCPacketError.invalidResponse) {
      try DDCDisplayEDID(bytes: Array(data.prefix(30)))
    }
  }

  @Test("Matching needs evidence in both directions and never falls back to transport or ordinal")
  func uniqueNameAndNoFallback() {
    let display = DDCDisplaySnapshot(
      id: UUID(), name: "lg 27", edid: nil, volume: DDCVCPValue(current: 75, maximum: 100))
    let matched = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "unit", name: " LG 27 Audio ", transport: .displayPort)],
      displays: [display])
    #expect(matched.bindings["unit"] == display.id && matched.unavailable["unit"] == nil)
    let unrelated = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "other", name: "HDMI", transport: .hdmi)],
      displays: [display])
    #expect(unrelated.bindings.isEmpty && unrelated.unavailable["other"] != nil)
    let bluetooth = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "bt", name: "LG 27", transport: .bluetooth)],
      displays: [display])
    #expect(bluetooth.bindings.isEmpty)
  }

  @Test("The isolated EDID prefix heuristic cannot be overridden by a contradicting fuzzy name")
  func edidEvidenceAndContradiction() {
    let edid = DDCDisplayEDID(vendorID: 0x1234, productID: 0x5678, serialNumber: 1)
    let display = DDCDisplaySnapshot(
      id: UUID(), name: "LG 27", edid: edid, volume: DDCVCPValue(current: 75, maximum: 100))
    let matched = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "12347856-opaque", name: "HDMI", transport: .hdmi)],
      displays: [display])
    #expect(matched.bindings["12347856-opaque"] == display.id)
    let wrong = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "ffffeeee-opaque", name: "LG 27", transport: .hdmi)],
      displays: [display])
    #expect(wrong.bindings.isEmpty && wrong.unavailable["ffffeeee-opaque"] != nil)
  }

  @Test("Same-name audio devices and same-model displays remain explicitly ambiguous")
  func ambiguousMapping() {
    let display = DDCDisplaySnapshot(
      id: UUID(), name: "LG 27", edid: nil, volume: DDCVCPValue(current: 75, maximum: 100))
    let manyAudio = DDCDeviceMatcher.match(
      candidates: [
        DDCAudioCandidate(uid: "a", name: "LG 27", transport: .hdmi),
        DDCAudioCandidate(uid: "b", name: "LG 27", transport: .displayPort),
      ], displays: [display])
    #expect(manyAudio.bindings.isEmpty && manyAudio.unavailable.count == 2)
    let edid = DDCDisplayEDID(vendorID: 0x1234, productID: 0x5678, serialNumber: 1)
    let a = DDCDisplaySnapshot(id: UUID(), name: "A", edid: edid, volume: display.volume)
    let b = DDCDisplaySnapshot(
      id: UUID(), name: "B",
      edid: DDCDisplayEDID(vendorID: 0x1234, productID: 0x5678, serialNumber: 2),
      volume: display.volume)
    let manyDisplays = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "12347856-opaque", name: "HDMI", transport: .hdmi)],
      displays: [a, b])
    #expect(manyDisplays.bindings.isEmpty && manyDisplays.unavailable.count == 1)
  }

  @Test("Unknown volume scales and invalid ranges cannot be silently normalized or clamped")
  func supportedVolumeScale() throws {
    #expect(try DDCVolumeScale.percent(of: DDCVCPValue(current: 75, maximum: 100)) == 75)
    for value in [DDCVCPValue(current: 0, maximum: 0), DDCVCPValue(current: 80, maximum: 255)] {
      do {
        _ = try DDCVolumeScale.percent(of: value)
        Issue.record("Unknown DDC scale was accepted")
      } catch DeviceBackendError.unsupported {} catch {
        Issue.record("Expected an unsupported-scale error")
      }
    }
    #expect(throws: DDCPacketError.invalidResponse) {
      try DDCVolumeScale.percent(of: DDCVCPValue(current: 101, maximum: 100))
    }
    let unsupported = DDCDisplaySnapshot(
      id: UUID(), name: "LG", edid: nil, volume: DDCVCPValue(current: 80, maximum: 255))
    let match = DDCDeviceMatcher.match(
      candidates: [DDCAudioCandidate(uid: "unit", name: "LG", transport: .displayPort)],
      displays: [unsupported])
    #expect(match.bindings.isEmpty && match.unavailable["unit"] != nil)
  }

  private var volumeReply: [UInt8] { [0x6E, 0x88, 0x02, 0, 0x62, 0, 0, 100, 0, 75, 0xF9] }
}

private final class DDCWireFixture {
  struct Write {
    let chip: UInt32
    let address: UInt32
    let bytes: [UInt8]
  }

  struct Read: Equatable {
    let chip: UInt32
    let address: UInt32
    let count: Int
  }

  private var replies: [[UInt8]]
  private var writeStatuses: [Int32]
  var writes: [Write] = []
  var reads: [Read] = []
  var events: [String] = []

  init(replies: [[UInt8]], writeStatuses: [Int32] = []) {
    self.replies = replies
    self.writeStatuses = writeStatuses
  }

  var operations: DDCI2COperations {
    DDCI2COperations(
      write: { [self] chip, address, bytes in
        events.append("write")
        writes.append(Write(chip: chip, address: address, bytes: bytes))
        let status = writeStatuses.isEmpty ? 0 : writeStatuses.removeFirst()
        if status != 0 { throw DeviceBackendError.osStatus(status) }
      },
      read: { [self] chip, address, count in
        events.append("read\(count)")
        reads.append(Read(chip: chip, address: address, count: count))
        guard !replies.isEmpty else { throw DDCPacketError.invalidResponse }
        return replies.removeFirst()
      },
      sleepMilliseconds: { [self] in events.append("sleep\($0)") })
  }
}
