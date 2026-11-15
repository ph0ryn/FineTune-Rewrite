import Foundation
import Observation
import Testing

@testable import FineTunePlatform

@Suite("DDC packet and device backend", .timeLimit(.minutes(1)))
@MainActor
struct DDCDeviceBackendTests {
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

  @Test("The real controller is inert until start and owns discovery/notification lifetime")
  func controllerLifetime() async throws {
    let rig = DDCTestRig()
    #expect(await rig.transport.discoverCalls == 0)
    #expect(rig.candidates.readCount == 0 && rig.notifications.active == 0)
    await rig.ready()
    #expect(rig.backend.states["unit"]?.observedPercent == 75)
    #expect(rig.backend.states["unit"]?.isMuted == false && rig.notifications.active == 1)
    #expect(await rig.transport.writes.isEmpty)
    #expect(rig.preferences.volumes.isEmpty)
    #expect(
      throws: DeviceBackendError.operationFailed(
        "The selected device's DDC display is not currently available."
      )
    ) { try rig.backend.requestVolume(forUID: "removed", to: 0.5) }
    let callback = rig.notifications.callbacks.first
    await rig.backend.stop()
    let calls = await rig.transport.discoverCalls
    callback?()
    #expect(rig.notifications.active == 0 && rig.backend.states.isEmpty)
    #expect(await rig.transport.discoverCalls == calls)
  }

  @Test("Trailing volume coalescing publishes actual readback and only the latest persisted wish")
  func controllerDebounce() async throws {
    let rig = DDCTestRig()
    var supersededWriteForCleanup: Task<Void, Never>?
    var replacementWriteForCleanup: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        let supersededWrite = rig.backend.currentWriteTasks()["unit"]
        supersededWriteForCleanup = supersededWrite
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        let replacementWrite = rig.backend.currentWriteTasks()["unit"]
        replacementWriteForCleanup = replacementWrite
        try await rig.clock.waitForSleepCount(2)
        #expect(rig.backend.states["unit"]?.observedPercent == 75)
        await rig.clock.advance(by: .milliseconds(100))
        if let supersededWrite {
          try await waitForOwnedTask(
            supersededWrite, waitedFor: "the superseded DDC write",
            releasing: { await rig.clock.cancelAllSleeps() })
        }
        if let replacementWrite {
          try await waitForOwnedTask(
            replacementWrite, waitedFor: "the replacement DDC write",
            releasing: { await rig.clock.cancelAllSleeps() })
        }
        await rig.waitForIdle()
        #expect(await rig.transport.writes == [80])
        #expect(rig.backend.states["unit"]?.observedPercent == 80)
        #expect(rig.backend.states["unit"]?.requestedPercent == nil)
        #expect(rig.preferences.getDDCVolume(for: "unit") == 80)
        await rig.backend.stop()
      },
      cleanup: {
        await rig.cleanUpAfterFailure(
          additionalTasks: [
            supersededWriteForCleanup,
            replacementWriteForCleanup,
          ].compactMap { $0 })
      })
  }

  @Test("A debounce shortfall is reported, released and drained instead of parking the suite")
  func controllerDebounceShortfallCleansUp() async throws {
    let rig = DDCTestRig()
    var writeForCleanup: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        try await rig.clock.waitForSleepCount(1)
        let write = try #require(rig.backend.currentWriteTasks()["unit"])
        writeForCleanup = write
        // The 99ms advance cannot reach the 100ms debounce; the old unbounded `task.value` await
        // here was the reviewed hang and did not return on the suite time limit.
        await rig.clock.advance(by: .milliseconds(99))
        do {
          try await waitForOwnedTask(
            write, waitedFor: "the short-fallen DDC write", timeout: .milliseconds(100),
            releasing: { await rig.clock.cancelAllSleeps() })
          Issue.record("The short-fallen DDC write was reported as complete")
        } catch let failure as TestTaskWaitTimeout {
          // Expected: the missed deadline is thrown after the release and bounded drain above.
          #expect(failure.finishedAfterRelease)
        }
        #expect(rig.backend.states["unit"]?.isApplying == false)
        #expect(rig.backend.states["unit"]?.error != nil)
        await rig.waitForIdle()
        #expect(await rig.transport.writes.isEmpty)
        await rig.backend.stop()
      },
      cleanup: {
        await rig.cleanUpAfterFailure(additionalTasks: writeForCleanup.map { [$0] } ?? [])
      })
  }

  @Test("Returning to the observed value cancels a not-yet-issued write without leaving pending UI")
  func cancelledBackToObserved() async throws {
    let rig = DDCTestRig()
    var cancelledWriteForCleanup: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        let cancelledWrite = rig.backend.currentWriteTasks()["unit"]
        cancelledWriteForCleanup = cancelledWrite
        try rig.backend.requestVolume(forUID: "unit", to: 0.75)
        #expect(rig.backend.states["unit"]?.isApplying == false)
        #expect(rig.backend.states["unit"]?.requestedPercent == nil)
        #expect(await rig.transport.writes.isEmpty)
        if let cancelledWrite { await cancelledWrite.value }
        await rig.backend.stop()
      },
      cleanup: {
        await rig.cleanUpAfterFailure(
          additionalTasks: cancelledWriteForCleanup.map { [$0] } ?? [])
      })
  }

  @Test("Returning to the old observation still compensates an already-issued physical write")
  func issuedWriteNeedsCompensation() async throws {
    let rig = DDCTestRig()
    var issuedWriteForCleanup: Task<Void, Never>?
    var replacementWriteForCleanup: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        await rig.transport.setHoldWrites(true)
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.transport.waitForWriteCount(1)
        let issuedWrite = try #require(rig.backend.currentWriteTasks()["unit"])
        issuedWriteForCleanup = issuedWrite
        try rig.backend.requestVolume(forUID: "unit", to: 0.75)
        let replacementWrite = rig.backend.currentWriteTasks()["unit"]
        replacementWriteForCleanup = replacementWrite
        if rig.backend.states["unit"]?.isApplying != true {
          Issue.record(
            "An issued write can still change hardware; its old observation is not a confirmed latest target"
          )
          await rig.backend.stop()
          await rig.transport.completeHeld(value: DDCVCPValue(current: 20, maximum: 100))
          await issuedWrite.value
          if let replacementWrite { await replacementWrite.value }
          return
        }
        await rig.transport.completeHeld(value: DDCVCPValue(current: 20, maximum: 100))
        try await rig.transport.waitForReturnCount(1)
        // The transport event precedes the task's remaining work; await that exact issued task.
        await issuedWrite.value
        await rig.transport.setHoldWrites(false)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        if let replacementWrite {
          try await waitForOwnedTask(
            replacementWrite, waitedFor: "the replacement DDC write",
            releasing: { await rig.clock.cancelAllSleeps() })
        }
        await rig.waitForIdle()
        #expect(await rig.transport.writes == [20, 75])
        #expect(rig.backend.states["unit"]?.observedPercent == 75)
        await rig.backend.stop()
      },
      cleanup: {
        await rig.cleanUpAfterFailure(
          additionalTasks: [issuedWriteForCleanup, replacementWriteForCleanup].compactMap { $0 })
      })
  }

  @Test("An unknown readback scale terminates pending work and removes write capability")
  func unknownWriteReadbackScale() async throws {
    let rig = DDCTestRig()
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        await rig.transport.setMaximum(255)
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == nil)
        #expect(rig.backend.states["unit"]?.error != nil)
        #expect(
          throws: DeviceBackendError.operationFailed(
            "Non-percentage DDC speaker volume is not supported by this device."
          )
        ) { try rig.backend.requestVolume(forUID: "unit", to: 0.5) }
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUpAfterFailure() })
  }

  @Test("Mute saves logical volume, requires zero readback and restores an edited muted wish")
  func muteRestore() async throws {
    let rig = DDCTestRig()
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestMute(forUID: "unit", to: true)
        #expect(rig.backend.states["unit"]?.isMuted == false)
        #expect(
          rig.preferences.getDDCSavedVolume(for: "unit") == 75 && rig.preferences.flushCount == 1)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == 0)
        #expect(rig.backend.states["unit"]?.isMuted == true)
        #expect(rig.backend.states["unit"]?.requestedPercent == 75)
        try rig.backend.requestVolume(forUID: "unit", to: 0.4)
        #expect(await rig.transport.writes == [0])
        #expect(rig.backend.states["unit"]?.requestedPercent == 40)
        try rig.backend.requestMute(forUID: "unit", to: false)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        await rig.waitForIdle()
        #expect(await rig.transport.writes == [0, 40])
        #expect(rig.backend.states["unit"]?.observedPercent == 40)
        #expect(rig.backend.states["unit"]?.isMuted == false)
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUpAfterFailure() })
  }

  @Test(
    "Mismatched readback stays observed, reports failure, and late mute completion cannot republish"
  )
  func mismatchAndLateMute() async throws {
    let rig = DDCTestRig()
    var pendingWriteForCleanup: Task<Void, Never>?
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        await rig.transport.setReadbackOverride(55)
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == 55)
        #expect(rig.backend.states["unit"]?.error != nil && rig.backend.lastError != nil)
        await rig.transport.setHoldWrites(true)
        try rig.backend.requestMute(forUID: "unit", to: true)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.transport.waitForWriteCount(2)
        #expect(rig.backend.states["unit"]?.isMuted == false)
        let pendingWrite = try #require(rig.backend.currentWriteTasks()["unit"])
        pendingWriteForCleanup = pendingWrite
        await rig.backend.stop()
        await rig.transport.completeHeld(value: DDCVCPValue(current: 0, maximum: 100))
        try await rig.transport.waitForReturnCount(2)
        // The transport event precedes the task's remaining work; await that exact task to decide.
        await pendingWrite.value
        #expect(rig.backend.states.isEmpty)
      },
      cleanup: {
        await rig.cleanUpAfterFailure(
          additionalTasks: pendingWriteForCleanup.map { [$0] } ?? [])
      })
  }

  @Test("Saved volume is restored only after explicit start, current UID and a supported probe")
  func savedRestore() async throws {
    let rig = DDCTestRig(storedVolume: 60)
    try await withFailureCleanup(
      operation: {
        #expect(await rig.transport.writes.isEmpty)
        await rig.ready()
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        await rig.waitForIdle()
        #expect(await rig.transport.writes == [60])
        rig.candidates.values = []
        #expect(
          throws: DeviceBackendError.operationFailed(
            "The selected device's DDC display is not currently available."
          )
        ) { try rig.backend.requestVolume(forUID: "unit", to: 0.5) }
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUpAfterFailure() })
  }

  @Test("A failed pre-mute preference flush cannot mute hardware or claim success")
  func failedMutePersistence() async throws {
    let rig = DDCTestRig()
    await rig.ready()
    rig.preferences.nextFlushError = "Disk full"
    #expect(
      throws: DeviceBackendError.operationFailed(
        "The pre-mute display volume could not be saved: Disk full"
      )
    ) { try rig.backend.requestMute(forUID: "unit", to: true) }
    #expect(rig.backend.states["unit"]?.isMuted == false)
    #expect(await rig.transport.writes.isEmpty)
    #expect(rig.backend.states["unit"]?.error != nil)
    await rig.backend.stop()
  }

  @Test("An unsupported reprobe loses write capability, not the saved desired volume")
  func unavailableReprobe() async throws {
    let rig = DDCTestRig(storedVolume: 75)
    await rig.ready()
    await rig.transport.setMaximum(255)
    await rig.backend.probe()
    #expect(rig.backend.states["unit"]?.observedPercent == nil)
    #expect(rig.backend.states["unit"]?.error != nil)
    #expect(rig.backend.unavailableReasons["unit"] != nil)
    #expect(rig.preferences.getDDCVolume(for: "unit") == 75)
    #expect(
      throws: DeviceBackendError.operationFailed(
        "Non-percentage DDC speaker volume is not supported by this device."
      )
    ) { try rig.backend.requestVolume(forUID: "unit", to: 0.5) }
    #expect(await rig.transport.writes.isEmpty)
    await rig.backend.stop()
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

@MainActor
private final class DDCTestRig {
  let clock: DeviceBackendTestClock
  let candidates: DDCCandidateFixture
  let preferences: DDCPreferenceFixture
  let notifications: DDCNotificationFixture
  let transport: DDCFixtureTransport
  let backend: DDCVolumeBackend

  init(storedVolume: Int? = nil) {
    let clock = DeviceBackendTestClock()
    let candidates = DDCCandidateFixture()
    let preferences = DDCPreferenceFixture()
    let notifications = DDCNotificationFixture()
    let transport = DDCFixtureTransport()
    if let storedVolume { preferences.volumes["unit"] = storedVolume }
    self.clock = clock
    self.candidates = candidates
    self.preferences = preferences
    self.notifications = notifications
    self.transport = transport
    backend = DDCVolumeBackend(
      transport: transport, preferences: preferences, candidates: { candidates.read() },
      displayChanges: notifications, clock: DeviceBackendClock { try await clock.sleep(for: $0) })
  }

  func ready() async {
    backend.start()
    let scheduledProbe = backend.scheduledProbe
    await backend.probe()
    await scheduledProbe?.value
  }

  /// Awaits the write tasks the backend owns instead of a transient `isApplying` observation.
  /// Each wait is bounded, so a missed manual-clock deadline is diagnosed instead of parking.
  func waitForIdle() async {
    while true {
      let tasks = Array(backend.currentWriteTasks().values)
      if tasks.isEmpty { return }
      for task in tasks {
        do {
          try await waitForOwnedTask(
            task, waitedFor: "the DDC write to become idle",
            releasing: { await clock.cancelAllSleeps() })
        } catch {
          Issue.record("\(error)")
          return
        }
      }
    }
  }

  /// Releases held fixture writes and drains owned tasks if a test exits through an error.
  /// Every drain is bounded so failure cleanup cannot itself park the suite.
  func cleanUpAfterFailure(additionalTasks: [Task<Void, Never>] = []) async {
    var tasks = Array(backend.currentWriteTasks().values)
    tasks.append(contentsOf: additionalTasks)
    await backend.stop()
    await transport.completeHeld(value: DDCVCPValue(current: 75, maximum: 100))
    await clock.cancelAllSleeps()
    await drainOwnedTasks(tasks, waitedFor: "DDC failure cleanup")
  }
}

@MainActor
private final class DDCCandidateFixture {
  var values = [DDCAudioCandidate(uid: "unit", name: "LG 27", transport: .displayPort)]
  var readCount = 0
  func read() -> [DDCAudioCandidate] {
    readCount += 1
    return values
  }
}

@MainActor
private final class DDCNotificationFixture: DisplayParameterObserving {
  var active = 0
  var callbacks: [@MainActor @Sendable () -> Void] = []
  func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    active += 1
    callbacks.append(onChange)
    return DevicePropertyObservation { [weak self] in self?.active -= 1 }
  }
}

@MainActor
private final class DDCPreferenceFixture: DDCPreferenceStoring {
  var volumes: [String: Int] = [:]
  private var muted: [String: Bool] = [:]
  private var saved: [String: Int] = [:]
  var lastSaveError: String?
  var nextFlushError: String?
  var flushCount = 0
  func getDDCVolume(for deviceUID: String) -> Int? { volumes[deviceUID] }
  func setDDCVolume(for deviceUID: String, to volume: Int) { volumes[deviceUID] = volume }
  func getDDCMuteState(for deviceUID: String) -> Bool { muted[deviceUID] ?? false }
  func setDDCMuteState(for deviceUID: String, to value: Bool) { muted[deviceUID] = value }
  func getDDCSavedVolume(for deviceUID: String) -> Int? { saved[deviceUID] }
  func setDDCSavedVolume(for deviceUID: String, to volume: Int) { saved[deviceUID] = volume }
  func flushSync() {
    flushCount += 1
    lastSaveError = nextFlushError
  }
}

private actor DDCFixtureTransport: DDCDisplayTransport {
  private let id = UUID()
  private var current: UInt16 = 75
  private var maximum: UInt16 = 100
  private var readbackOverride: UInt16?
  private var holdWrites = false
  private var pending: [CheckedContinuation<DDCVCPValue, any Error>] = []
  private var returned = 0
  private let writeEntries: AsyncStream<Int>
  private let writeEntryEvents: AsyncStream<Int>.Continuation
  private let writeReturns: AsyncStream<Int>
  private let writeReturnEvents: AsyncStream<Int>.Continuation
  var discoverCalls = 0
  var writes: [Int] = []

  /// Events carry the cumulative count so a wait can target a count reached before it began.
  init() {
    let entries = AsyncStream<Int>.makeStream()
    let returns = AsyncStream<Int>.makeStream()
    writeEntries = entries.stream
    writeEntryEvents = entries.continuation
    writeReturns = returns.stream
    writeReturnEvents = returns.continuation
  }

  func discover() async throws -> [DDCDisplaySnapshot] {
    discoverCalls += 1
    return [
      DDCDisplaySnapshot(
        id: id, name: "LG 27", edid: nil, volume: DDCVCPValue(current: current, maximum: maximum))
    ]
  }

  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    guard displayID == id else { throw DeviceBackendError.unavailableDevice(displayID.uuidString) }
    writes.append(percent)
    writeEntryEvents.yield(writes.count)
    let value: DDCVCPValue
    if holdWrites {
      value = try await withCheckedThrowingContinuation { continuation in
        pending.append(continuation)
      }
    } else {
      value = DDCVCPValue(current: readbackOverride ?? UInt16(percent), maximum: maximum)
    }
    current = value.current
    returned += 1
    writeReturnEvents.yield(returned)
    return value
  }

  func readVolume(displayID: UUID) async throws -> DDCVCPValue {
    guard displayID == id else { throw DeviceBackendError.unavailableDevice(displayID.uuidString) }
    return DDCVCPValue(current: current, maximum: maximum)
  }

  func close() async throws {}
  func setMaximum(_ value: UInt16) { maximum = value }
  func setReadbackOverride(_ value: UInt16?) { readbackOverride = value }
  func setHoldWrites(_ value: Bool) { holdWrites = value }
  func completeHeld(value: DDCVCPValue) {
    let all = pending
    pending.removeAll()
    for continuation in all { continuation.resume(returning: value) }
  }
  /// Each event count has one five-second deadline; a missing event fails locally.
  func waitForWriteCount(_ count: Int) async throws {
    _ = try await waitForStreamValue(
      in: writeEntries, finishing: writeEntryEvents,
      waitedFor: "DDC write entry count \(count)", matches: { $0 >= count })
  }

  func waitForReturnCount(_ count: Int) async throws {
    _ = try await waitForStreamValue(
      in: writeReturns, finishing: writeReturnEvents,
      waitedFor: "DDC write return count \(count)", matches: { $0 >= count })
  }
}
