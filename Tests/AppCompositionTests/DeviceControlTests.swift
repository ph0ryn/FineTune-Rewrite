import AudioToolbox
import FineTuneDomain
import FineTunePlatform
import SwiftUI
import Testing

@testable import FineTune

@Suite("Device control components")
@MainActor
struct DeviceControlTests {
  @Test("Unknown input values have no writable slider binding")
  func unknownInputRow() {
    var writes: [Float] = []
    let row = DeviceRow(
      device: fixtureDevice, isDefault: false, volume: nil, isMuted: nil,
      canSetVolume: false, canSetMute: false, isInput: true,
      onSetDefault: {}, onVolumeChange: { writes.append($0) }, onMuteToggle: {})
    #expect(row.slider == nil)
    #expect(writes.isEmpty)
  }

  @Test("A volume-only input uses the real row's linear slider binding")
  func partialInputRowBinding() throws {
    var writes: [Float] = []
    let row = DeviceRow(
      device: fixtureDevice, isDefault: false, volume: 0.3, isMuted: nil,
      canSetVolume: true, canSetMute: false, isInput: true,
      onSetDefault: {}, onVolumeChange: { writes.append($0) }, onMuteToggle: {})
    let slider = try #require(row.slider)
    #expect(abs(slider.wrappedValue - 0.3) < 0.000_001)
    slider.wrappedValue = 0.7
    #expect(writes == [0.7])
  }

  @Test("Read-only output volume cannot expose a setter even when its value is known")
  func readOnlyOutputRow() {
    let row = DeviceRow(
      device: fixtureDevice, isDefault: false, volume: 0.4, isMuted: false,
      canSetVolume: false, canSetMute: true,
      onSetDefault: {}, onVolumeChange: { _ in Issue.record("Unexpected read-only write") },
      onMuteToggle: {})
    #expect(row.slider == nil)
  }

  @Test("Input inspectors have no output-only override action or toggle")
  func inputInspectorAvailability() {
    let sheet = DeviceDetailSheet(
      device: fixtureDevice, transportType: .usb, autoDetectedTier: .hardware,
      currentOverride: nil, isInput: true, allowsVolumeOverride: false,
      onOverrideChange: nil, onDismiss: {})
    #expect(sheet.onOverrideChange == nil)
    #expect(
      !DeviceDetailSheet.shouldShowToggle(
        autoTier: .hardware, isInput: true, allowsVolumeOverride: true, hasOverrideAction: false))
    #expect(
      !DeviceDetailSheet.shouldShowToggle(
        autoTier: .hardware, isInput: false, allowsVolumeOverride: true, hasOverrideAction: false))
    #expect(DeviceDetailSheet.shouldShowToggle(autoTier: .hardware))
  }

  @Test("The inspector observes external sample-rate and hog changes without real HAL I/O")
  func inspectorLiveObservations() throws {
    let hal = InspectorFixtureHAL()
    hal.prepare(device: 999, rate: 48_000, hogOwner: -1, input: true)
    var lookups = 0
    let model = DeviceInspectorModel(
      device: fixtureDevice, transport: .usb, isInput: true, reader: hal, writer: hal,
      observer: hal,
      resolveUID: { uid in
        #expect(uid == "unit-device")
        lookups += 1
        return 999
      })
    #expect(hal.reads == 0 && lookups == 0 && hal.activeObservations == 0)
    model.start()
    model.start()
    #expect(model.info?.sampleRate == 48_000)
    #expect(hal.activeObservations == 2)
    hal.prepare(device: 999, rate: 44_100, hogOwner: 123, input: true)
    hal.emit(kAudioDevicePropertyNominalSampleRate)
    #expect(model.info?.sampleRate == 44_100 && model.info?.hogModeOwner == 123)
    #expect(model.error == nil)
    let callbacks = hal.callbacks.map(\.callback)
    model.stop()
    model.stop()
    let reads = hal.reads
    for callback in callbacks { callback() }
    #expect(hal.reads == reads && hal.activeObservations == 0)
  }

  @Test("Inspector writes resolve the current UID and cannot fabricate a successful sample rate")
  func inspectorUIDAndWriteFailure() {
    let hal = InspectorFixtureHAL()
    hal.prepare(device: 1001, rate: 48_000, hogOwner: -1, input: false)
    var available = true
    let model = DeviceInspectorModel(
      device: fixtureDevice, transport: .usb, reader: hal, writer: hal, observer: hal,
      resolveUID: { _ in
        guard available else { throw DeviceBackendError.unavailableDevice("unit-device") }
        return 1001
      })
    model.start()
    model.selectSampleRate(44_100)
    #expect(hal.writes == [1001])
    #expect(model.info?.sampleRate == 44_100)
    available = false
    model.selectSampleRate(96_000)
    #expect(hal.writes == [1001] && model.error != nil)
    #expect(model.info?.sampleRate == 44_100)
    model.stop()
  }

  private var fixtureDevice: AudioDevice {
    AudioDevice(
      id: 999, uid: "unit-device", name: "Unit microphone", icon: nil, supportsAutoEQ: false)
  }
}

nonisolated private final class InspectorFixtureHAL: AudioDevicePropertyReading,
  AudioDevicePropertyWriting, AudioDevicePropertyObserving
{
  private struct Key: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
  }
  private var values: [Key: Any] = [:]
  var reads = 0
  var writes: [AudioDeviceID] = []
  @MainActor var activeObservations = 0
  @MainActor var callbacks:
    [(selector: AudioObjectPropertySelector, callback: @MainActor @Sendable () -> Void)] = []

  func prepare(device: AudioDeviceID, rate: Double, hogOwner: Int32, input: Bool) {
    let global = kAudioObjectPropertyScopeGlobal
    values[Key(object: device, selector: kAudioDevicePropertyNominalSampleRate, scope: global)] =
      rate
    values[Key(object: device, selector: kAudioDevicePropertyHogMode, scope: global)] = hogOwner
    values[
      Key(object: device, selector: kAudioDevicePropertyAvailableNominalSampleRates, scope: global)] =
      [
        AudioValueRange(mMinimum: rate, mMaximum: rate)
      ]
    values[
      Key(
        object: device, selector: kAudioDevicePropertyStreams,
        scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)] = [
        AudioStreamID
      ]()
  }

  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value {
    reads += 1
    guard let value = values[Key(object: object, selector: selector, scope: scope)] as? Value else {
      throw DeviceBackendError.operationFailed("Unexpected scalar fixture read.")
    }
    return value
  }

  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value] {
    reads += 1
    guard let value = values[Key(object: object, selector: selector, scope: scope)] as? [Value]
    else {
      throw DeviceBackendError.operationFailed("Unexpected array fixture read.")
    }
    return value
  }

  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool { values[Key(object: object, selector: selector, scope: scope)] != nil }

  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool { selector == kAudioDevicePropertyNominalSampleRate }

  @MainActor
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, value: Value
  ) throws {
    #expect(scope == kAudioObjectPropertyScopeGlobal)
    writes.append(object)
    values[Key(object: object, selector: selector, scope: scope)] = value
  }

  @MainActor
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    #expect(scope == kAudioObjectPropertyScopeGlobal)
    activeObservations += 1
    callbacks.append((selector, onChange))
    return DevicePropertyObservation { [weak self] in self?.activeObservations -= 1 }
  }

  @MainActor
  func emit(_ selector: AudioObjectPropertySelector) {
    for registration in callbacks where registration.selector == selector {
      registration.callback()
    }
  }
}
