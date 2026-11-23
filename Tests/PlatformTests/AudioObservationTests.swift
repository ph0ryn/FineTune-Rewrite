import AppKit
import AudioToolbox
import FineTuneDomain
import Testing

@testable import FineTunePlatform

@Suite("Healthy audio observation")
@MainActor
struct AudioObservationTests {
  @Test("Cold observers are explicitly not started, not healthy empty discovery")
  func coldObserversAreUnobserved() {
    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    #expect(devices.observation.health == .notStarted)
    #expect(processes.observation.health == .notStarted)
    #expect(devices.observation.revision == 0)
    #expect(processes.observation.revision == 0)
    let source = DeviceObservationFixture()
    #expect(source.reader.reads == 0)
    #expect(source.observer.registrations.isEmpty)
  }

  @Test("Fixtures keep zero revisions and entity equality remains UID identity")
  func deviceRevisionContract() {
    let fixture = AudioDevice(
      id: 11, uid: "device", name: "Device", icon: nil, supportsAutoEQ: true)
    #expect(fixture.bindingRevision == 0)
    #expect(fixture.formatRevision == 0)
    #expect(fixture.transportType == .unknown)
    let observed = AudioDevice(
      id: 12, uid: "device", name: "Renamed", icon: nil, supportsAutoEQ: true, bindingRevision: 3,
      formatRevision: 4)
    #expect(observed.bindingRevision == 3)
    #expect(observed.formatRevision == 4)
    #expect(fixture == observed)
  }

  @Test(
    "Both stream roles retain actual transport, never inferred from Bluetooth or Built-in names",
    arguments: [false, true],
    [TransportType.builtIn, .usb, .bluetooth, .bluetoothLE, .unknown])
  func inventoryTransportIsPreserved(input: Bool, transport: TransportType) throws {
    let source = DeviceObservationFixture()
    source.reader.inventory = observationDevices([
      observationDevice(name: "Bluetooth Built-in", transport: transport, input: input)
    ])
    #expect(source.reader.reads == 0)
    source.monitor.refresh()
    let devices = input ? source.monitor.inputDevices : source.monitor.outputDevices
    let device = try #require(devices.first)
    #expect(device.transportType == transport)
    #expect(source.monitor.observation.health == .healthy)
    #expect(source.reader.reads == 1)
  }

  @Test(
    "Same UID transport metadata is visible before notification without a false native rebinding",
    arguments: [false, true])
  func transportMetadataPublishesBeforeCallback(input: Bool) throws {
    let source = DeviceObservationFixture()
    source.reader.inventory = observationDevices([
      observationDevice(transport: .bluetoothLE, input: input)
    ])
    source.monitor.refresh()
    let first = try #require(
      (input ? source.monitor.inputDevices : source.monitor.outputDevices).first)
    let revision = source.monitor.observation.revision
    var notifications = 0
    source.monitor.onObservationChanged = {
      let current = input ? source.monitor.inputDevices : source.monitor.outputDevices
      #expect(current.first?.transportType == .usb)
      #expect(source.monitor.observation.revision > revision)
      notifications += 1
    }
    source.reader.inventory = observationDevices([
      observationDevice(transport: .usb, input: input)
    ])
    source.monitor.refresh()
    let changed = try #require(
      (input ? source.monitor.inputDevices : source.monitor.outputDevices).first)
    #expect(changed == first)
    #expect(changed.transportType == .usb)
    #expect(changed.bindingRevision == first.bindingRevision)
    #expect(changed.formatRevision == first.formatRevision)
    #expect(notifications == 1)
    source.monitor.onObservationChanged = nil
    source.reader.failure = ObservationTestError.reader
    source.monitor.refresh()
    #expect(
      (input ? source.monitor.inputDevices : source.monitor.outputDevices).first?.transportType
        == .usb)
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Transport inventory failure was healthy")
    }
  }

  @Test("A rate change is published only after the settling window, then fires once")
  func publicationOrder() async throws {
    let source = DeviceObservationFixture()
    let settled = CountSignal()
    source.monitor.onDeviceConnected = { uid, _ in
      #expect(source.monitor.outputDevices.contains { $0.uid == uid })
      #expect(source.monitor.observation.health == .healthy)
      #expect(source.monitor.observation.revision > 0)
    }
    source.monitor.onDeviceDisconnected = { uid, _ in
      #expect(!source.monitor.outputDevices.contains { $0.uid == uid })
    }
    source.monitor.onSampleRateChanged = { uid, rate in
      #expect(uid == "device")
      #expect(rate == 96_000)
      #expect(source.monitor.outputDevices[0].formatRevision > 1)
      settled.emit()
    }
    var revisions: [UInt64] = []
    source.monitor.onObservationChanged = { revisions.append(source.monitor.observation.revision) }
    source.monitor.refresh()
    source.reader.inventory = observationDevices([observationDevice(rate: 96_000)])
    source.monitor.refresh()
    let held = try #require(source.monitor.outputDevices.first)
    #expect(held.formatRevision == 1)
    #expect(revisions == [1])
    try await source.settleRateChange()
    try await settled.wait(forCount: 1, waitedFor: "the settled rate callback")
    #expect(revisions == [1, 2])
    source.reader.inventory = observationDevices([])
    source.monitor.refresh()
    #expect(revisions == [1, 2, 3])
    #expect(source.monitor.outputDevices.isEmpty)
  }

  @Test("A rate that reverts before settling keeps later transitions observable")
  func rateRevertKeepsLaterTransitionsObservable() async throws {
    let source = DeviceObservationFixture()
    source.monitor.refresh()
    let settled = CountSignal()
    source.monitor.onSampleRateChanged = { _, _ in settled.emit() }

    source.reader.inventory = observationDevices([observationDevice(rate: 96_000)])
    source.monitor.refresh()
    #expect(source.monitor.outputDevices.first?.formatRevision == 1)
    source.reader.inventory = observationDevices([observationDevice(rate: 48_000)])
    source.monitor.refresh()
    #expect(source.monitor.outputDevices.first?.formatRevision == 1)

    source.reader.inventory = observationDevices([observationDevice(rate: 44_100)])
    source.monitor.refresh()
    // Let the newly armed settling task register its sleeper before driving the virtual clock.
    for _ in 0..<20 { await Task.yield() }
    await source.clock.advance(by: AudioDeviceMonitor.rateSettlingInterval)
    try await settled.wait(forCount: 1, waitedFor: "the later settled rate callback")
    #expect(source.monitor.outputDevices.first?.formatRevision == 2)
  }

  @Test("Same UID name/AutoEQ metadata publishes without pretending that the device reconnected")
  func metadataAndBindingRevisions() async throws {
    let source = DeviceObservationFixture()
    var connections = 0
    source.monitor.onDeviceConnected = { _, _ in connections += 1 }
    source.monitor.refresh()
    let first = try #require(source.monitor.outputDevices.first)
    let revision = source.monitor.observation.revision
    #expect(first.bindingRevision > 0)
    #expect(first.formatRevision > 0)
    source.reader.inventory = observationDevices([observationDevice(name: "Renamed", autoEQ: false)]
    )
    source.monitor.refresh()
    let metadata = try #require(source.monitor.outputDevices.first)
    #expect(metadata.name == "Renamed")
    #expect(!metadata.supportsAutoEQ)
    #expect(metadata.bindingRevision == first.bindingRevision)
    #expect(metadata.formatRevision == first.formatRevision)
    #expect(source.monitor.observation.revision > revision)
    #expect(connections == 1)
    source.reader.inventory = observationDevices([
      observationDevice(id: 12, name: "Renamed", autoEQ: false)
    ])
    source.monitor.refresh()
    let rebound = try #require(source.monitor.outputDevices.first)
    #expect(rebound.bindingRevision != metadata.bindingRevision)
    #expect(rebound.formatRevision == metadata.formatRevision)
    source.reader.inventory = observationDevices([observationDevice(id: 12, rate: 96_000)])
    source.monitor.refresh()
    let settledSignal = CountSignal()
    source.monitor.onSampleRateChanged = { _, _ in settledSignal.emit() }
    try await source.settleRateChange()
    try await settledSignal.wait(forCount: 1, waitedFor: "the settled rate callback")
    let formatted = try #require(source.monitor.outputDevices.first)
    #expect(formatted.bindingRevision != rebound.bindingRevision)
    #expect(formatted.formatRevision != rebound.formatRevision)
  }

  @Test("Changing physical format with unchanged UID/rate advances the native reprepare binding")
  func physicalFormatRevision() throws {
    let source = DeviceObservationFixture()
    source.monitor.refresh()
    let first = try #require(source.monitor.outputDevices.first)
    source.reader.inventory = observationDevices([observationDevice(channels: 6)])
    source.monitor.refresh()
    let changed = try #require(source.monitor.outputDevices.first)
    #expect(changed.formatRevision != first.formatRevision)
    #expect(changed.bindingRevision != first.bindingRevision)
  }

  @Test("Failed read or registration retains last good, not healthy empty or false disappearance")
  func failedReadAndRegistration() {
    let source = DeviceObservationFixture()
    source.monitor.refresh()
    var disconnected = 0
    source.monitor.onDeviceDisconnected = { _, _ in disconnected += 1 }
    source.reader.failure = ObservationTestError.reader
    source.monitor.refresh()
    #expect(source.monitor.outputDevices.map(\.uid) == ["device"])
    #expect(disconnected == 0)
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Read failure was healthy")
    }
    source.reader.failure = nil
    source.observer.failure = ObservationTestError.registration
    source.monitor.start()
    #expect(source.monitor.outputDevices.map(\.uid) == ["device"])
    #expect(source.monitor.lastError != nil)
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Registration failure was hidden")
    }
    source.monitor.stop()
  }

  @Test("Input physical changes on a duplex UID do not invalidate its unchanged output binding")
  func duplexRoleRevisions() throws {
    let source = DeviceObservationFixture()
    let output = observationDevice()
    let input = observationDevice(channels: 1)
    source.reader.inventory = observationDevices([
      AudioDeviceRecord(
        device: output.device, outputStreams: output.outputStreams,
        inputStreams: input.outputStreams, sampleRate: output.sampleRate)
    ])
    source.monitor.refresh()
    let oldOutput = try #require(source.monitor.outputDevices.first)
    let oldInput = try #require(source.monitor.inputDevices.first)
    let nextInput = observationDevice(channels: 6)
    source.reader.inventory = observationDevices([
      AudioDeviceRecord(
        device: output.device, outputStreams: output.outputStreams,
        inputStreams: nextInput.outputStreams, sampleRate: output.sampleRate)
    ])
    source.monitor.refresh()
    #expect(source.monitor.outputDevices.first?.bindingRevision == oldOutput.bindingRevision)
    #expect(source.monitor.inputDevices.first?.bindingRevision != oldInput.bindingRevision)
    #expect(source.monitor.inputDevices.first?.formatRevision != oldInput.formatRevision)
    #expect(source.monitor.inputDevices.first?.supportsAutoEQ == false)
  }

  @Test("Partial listener registration rolls back new tokens and can recover without false gone")
  func partialRegistrationRollback() {
    let source = DeviceObservationFixture()
    source.monitor.refresh()
    let old = source.monitor.outputDevices[0].bindingRevision
    source.reader.inventory = AudioDeviceInventory(
      devices: [observationDevice()],
      observationTargets: [
        AudioObservationTarget(object: .system, selector: kAudioHardwarePropertyDevices),
        AudioObservationTarget(object: 11, selector: kAudioObjectPropertyName),
      ])
    source.observer.failureAfter = 1
    source.monitor.start()
    #expect(source.observer.cancelled == 1)
    #expect(source.monitor.outputDevices[0].bindingRevision == old)
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Partial registration was healthy")
    }
    source.observer.failureAfter = nil
    source.monitor.refresh()
    #expect(source.monitor.observation.health == .healthy)
    #expect(source.monitor.outputDevices[0].bindingRevision == old)
    source.monitor.stop()
    #expect(source.observer.cancelled == source.observer.registrations.count)
  }

  @Test("Stopping cancels owned listeners and queued callbacks cannot read or publish again")
  func stoppedCallbacks() {
    let source = DeviceObservationFixture()
    source.monitor.start()
    let callbacks = source.observer.callbacks
    #expect(!callbacks.isEmpty)
    source.monitor.stop()
    let reads = source.reader.reads
    let revision = source.monitor.observation.revision
    for callback in callbacks { callback() }
    #expect(source.reader.reads == reads)
    #expect(source.monitor.observation.revision == revision)
    #expect(source.observer.cancelled == source.observer.registrations.count)
    source.monitor.stop()
    #expect(source.observer.cancelled == source.observer.registrations.count)
  }
}

@MainActor
func observationDevice(
  id: AudioDeviceID = 11, name: String = "Device", autoEQ: Bool = true, rate: Double = 48_000,
  channels: UInt32 = 2, transport: TransportType = .unknown, input: Bool = false
) -> AudioDeviceRecord {
  var format = AudioStreamBasicDescription()
  format.mSampleRate = rate
  format.mFormatID = kAudioFormatLinearPCM
  format.mFormatFlags = kAudioFormatFlagIsFloat
  format.mChannelsPerFrame = channels
  format.mBitsPerChannel = 32
  format.mBytesPerFrame = channels * 4
  format.mFramesPerPacket = 1
  format.mBytesPerPacket = channels * 4
  let streams = [AudioStreamRecord(id: 21, format: format)]
  return AudioDeviceRecord(
    device: AudioDevice(
      id: id, uid: "device", name: name, icon: nil, supportsAutoEQ: autoEQ,
      transportType: transport),
    outputStreams: input ? [] : streams, inputStreams: input ? streams : [], sampleRate: rate)
}

func observationDevices(_ devices: [AudioDeviceRecord]) -> AudioDeviceInventory {
  AudioDeviceInventory(
    devices: devices,
    observationTargets: [
      AudioObservationTarget(object: .system, selector: kAudioHardwarePropertyDevices)
    ])
}

@MainActor
final class ObservationTestDeviceReader: AudioDeviceInventoryReading {
  var inventory = observationDevices([observationDevice()])
  var failure: (any Error)?
  var reads = 0
  func readDevices() throws -> AudioDeviceInventory {
    reads += 1
    if let failure { throw failure }
    return inventory
  }
}

@MainActor
final class DeviceObservationFixture {
  let reader = ObservationTestDeviceReader()
  let observer = ObservationTestObserver()
  let clock = ManualTestClock()
  let monitor: AudioDeviceMonitor
  init() {
    let clock = self.clock
    monitor = AudioDeviceMonitor(
      inventory: reader, observer: observer,
      rateClock: DeviceBackendClock { duration in try await clock.sleep(for: duration) })
  }

  func settleRateChange() async throws {
    try await clock.waitForSleepCount(1)
    await clock.advance(by: AudioDeviceMonitor.rateSettlingInterval)
  }
}
