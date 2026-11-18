import Foundation
import Observation
import Testing

@testable import FineTunePlatform

@Suite("DDC volume backend controller", .timeLimit(.minutes(1)))
@MainActor
struct DDCDeviceBackendTests {
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
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        try await rig.clock.waitForSleepCount(2)
        #expect(rig.backend.states["unit"]?.observedPercent == 75)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.waitForIdle()
        #expect(await rig.transport.writes == [80])
        #expect(rig.backend.states["unit"]?.observedPercent == 80)
        #expect(rig.backend.states["unit"]?.requestedPercent == nil)
        #expect(rig.preferences.getDDCVolume(for: "unit") == 80)
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
  }

  @Test("Returning to the observed value cancels a not-yet-issued write without leaving pending UI")
  func cancelledBackToObserved() async throws {
    let rig = DDCTestRig()
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        try rig.backend.requestVolume(forUID: "unit", to: 0.75)
        #expect(rig.backend.states["unit"]?.isApplying == false)
        #expect(rig.backend.states["unit"]?.requestedPercent == nil)
        #expect(await rig.transport.writes.isEmpty)
        try await rig.waitForIdle()
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
  }

  @Test("Returning to the old observation still compensates an already-issued physical write")
  func issuedWriteNeedsCompensation() async throws {
    let rig = DDCTestRig()
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        await rig.transport.setHoldWrites(true)
        try rig.backend.requestVolume(forUID: "unit", to: 0.2)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.transport.waitForWriteCount(1)
        try rig.backend.requestVolume(forUID: "unit", to: 0.75)
        #expect(rig.backend.states["unit"]?.isApplying == true)
        await rig.transport.completeHeld(value: DDCVCPValue(current: 20, maximum: 100))
        try await rig.transport.waitForReturnCount(1)
        await rig.transport.setHoldWrites(false)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.waitForIdle()
        #expect(await rig.transport.writes == [20, 75])
        #expect(rig.backend.states["unit"]?.observedPercent == 75)
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
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
        try await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == nil)
        #expect(rig.backend.states["unit"]?.error != nil)
        #expect(
          throws: DeviceBackendError.operationFailed(
            "Non-percentage DDC speaker volume is not supported by this device."
          )
        ) { try rig.backend.requestVolume(forUID: "unit", to: 0.5) }
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
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
        try await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == 0)
        #expect(rig.backend.states["unit"]?.isMuted == true)
        #expect(rig.backend.states["unit"]?.requestedPercent == 75)
        try rig.backend.requestVolume(forUID: "unit", to: 0.4)
        #expect(await rig.transport.writes == [0])
        #expect(rig.backend.states["unit"]?.requestedPercent == 40)
        try rig.backend.requestMute(forUID: "unit", to: false)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.waitForIdle()
        #expect(await rig.transport.writes == [0, 40])
        #expect(rig.backend.states["unit"]?.observedPercent == 40)
        #expect(rig.backend.states["unit"]?.isMuted == false)
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
  }

  @Test(
    "Mismatched readback stays observed, reports failure, and late mute completion cannot republish"
  )
  func mismatchAndLateMute() async throws {
    let rig = DDCTestRig()
    try await withFailureCleanup(
      operation: {
        await rig.ready()
        await rig.transport.setReadbackOverride(55)
        try rig.backend.requestVolume(forUID: "unit", to: 0.8)
        try await rig.clock.waitForSleepCount(1)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.waitForIdle()
        #expect(rig.backend.states["unit"]?.observedPercent == 55)
        #expect(rig.backend.states["unit"]?.error != nil && rig.backend.lastError != nil)
        await rig.transport.setHoldWrites(true)
        try rig.backend.requestMute(forUID: "unit", to: true)
        try await rig.clock.waitForSleepCount(2)
        await rig.clock.advance(by: .milliseconds(100))
        try await rig.transport.waitForWriteCount(2)
        #expect(rig.backend.states["unit"]?.isMuted == false)
        await rig.backend.stop()
        await rig.transport.completeHeld(value: DDCVCPValue(current: 0, maximum: 100))
        try await rig.transport.waitForReturnCount(2)
        await Task.yield()
        #expect(rig.backend.states.isEmpty)
      },
      cleanup: { await rig.cleanUp() })
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
        try await rig.waitForIdle()
        #expect(await rig.transport.writes == [60])
        rig.candidates.values = []
        #expect(
          throws: DeviceBackendError.operationFailed(
            "The selected device's DDC display is not currently available."
          )
        ) { try rig.backend.requestVolume(forUID: "unit", to: 0.5) }
        await rig.backend.stop()
      },
      cleanup: { await rig.cleanUp() })
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
}

@MainActor
private final class DDCTestRig {
  let clock: ManualTestClock
  let candidates: DDCCandidateFixture
  let preferences: DDCPreferenceFixture
  let notifications: DDCNotificationFixture
  let transport: DDCFixtureTransport
  let backend: DDCVolumeBackend

  init(storedVolume: Int? = nil) {
    let clock = ManualTestClock()
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

  func waitForIdle() async throws {
    try await withMainActorTimeout(
      waitedFor: "DDC writes to become idle",
      onTimeout: { [weak self] in await self?.cleanUp() },
      operation: { [backend] in await backend.waitForCurrentWrites() })
  }

  func cleanUp() async {
    await backend.stop()
    await transport.completeHeld(value: DDCVCPValue(current: 75, maximum: 100))
    await clock.cancelAllSleeps()
    await Task.yield()
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
  private let writeEntries = CountSignal()
  private let writeReturns = CountSignal()
  var discoverCalls = 0
  var writes: [Int] = []

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
    writeEntries.emit()
    let value: DDCVCPValue
    if holdWrites {
      value = try await withCheckedThrowingContinuation { continuation in
        pending.append(continuation)
      }
    } else {
      value = DDCVCPValue(current: readbackOverride ?? UInt16(percent), maximum: maximum)
    }
    current = value.current
    writeReturns.emit()
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

  func waitForWriteCount(_ count: Int) async throws {
    try await writeEntries.wait(forCount: count, waitedFor: "DDC write entry \(count)")
  }

  func waitForReturnCount(_ count: Int) async throws {
    try await writeReturns.wait(forCount: count, waitedFor: "DDC write return \(count)")
  }
}
