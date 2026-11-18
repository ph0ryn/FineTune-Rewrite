// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from ronitsingh10/FineTune at upstream revision 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Originals: FineTuneTests/AudioDeviceInspectorPropertiesTests.swift, BTCallModeTransitionTests.swift

import AudioToolbox
import CoreAudio
import Foundation
import Testing

@testable import FineTunePlatform

private struct CompatInspectorPropertyQuery: Hashable {
  let object: AudioObjectID
  let selector: AudioObjectPropertySelector
  let scope: AudioObjectPropertyScope
}

private final class CompatInspectorPropertyReader: AudioDevicePropertyReading {
  enum ReadError: Error, Equatable { case unavailable }
  var values: [CompatInspectorPropertyQuery: Any] = [:]
  var present: Set<CompatInspectorPropertyQuery> = []
  var writable: [CompatInspectorPropertyQuery: Bool] = [:]
  var reads: [CompatInspectorPropertyQuery] = []
  var existenceChecks: [CompatInspectorPropertyQuery] = []
  var settableChecks: [CompatInspectorPropertyQuery] = []

  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value {
    let query = CompatInspectorPropertyQuery(object: object, selector: selector, scope: scope)
    reads.append(query)
    guard let value = values[query] as? Value else { throw ReadError.unavailable }
    return value
  }

  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value] {
    let query = CompatInspectorPropertyQuery(object: object, selector: selector, scope: scope)
    reads.append(query)
    guard let value = values[query] as? [Value] else { throw ReadError.unavailable }
    return value
  }

  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    let query = CompatInspectorPropertyQuery(object: object, selector: selector, scope: scope)
    existenceChecks.append(query)
    return present.contains(query)
  }

  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool {
    let query = CompatInspectorPropertyQuery(object: object, selector: selector, scope: scope)
    settableChecks.append(query)
    guard let value = writable[query] else { throw ReadError.unavailable }
    return value
  }
}

@Suite("Compat: Device inspector — injected CoreAudio property reads")
struct UpstreamAudioDeviceInspectorPropertiesTests {
  @Test("Global available-rate reads preserve discrete rates and continuous-range endpoints")
  func availableSampleRates() {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyAvailableNominalSampleRates,
      scope: kAudioObjectPropertyScopeGlobal)
    reader.values[query] = [
      AudioValueRange(mMinimum: 44_100, mMaximum: 44_100),
      AudioValueRange(mMinimum: 48_000, mMaximum: 96_000),
    ]

    let rates = AudioDeviceInspector(reader: reader).readAvailableSampleRates(for: 42)

    #expect(rates == [44_100, 48_000, 96_000])
    #expect(reader.reads == [query])
  }

  @Test("Unavailable sample-rate properties produce an empty list")
  func unavailableSampleRates() {
    let reader = CompatInspectorPropertyReader()
    var failures: [any Error] = []
    let inspector = AudioDeviceInspector(reader: reader, onFailure: { failures.append($0) })
    #expect(inspector.readAvailableSampleRates(for: 42).isEmpty)
    #expect((failures.first as? CompatInspectorPropertyReader.ReadError) == .unavailable)
    #expect(failures.count == 1)
    #expect(
      reader.reads == [
        CompatInspectorPropertyQuery(
          object: 42, selector: kAudioDevicePropertyAvailableNominalSampleRates,
          scope: kAudioObjectPropertyScopeGlobal)
      ])
  }

  @Test(
    "Hog-mode reads return the actual owner or unowned sentinel",
    arguments: [pid_t(-1), pid_t(1234)])
  func hogModeUnowned(owner: pid_t) {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyHogMode, scope: kAudioObjectPropertyScopeGlobal)
    reader.values[query] = owner
    #expect(AudioDeviceInspector(reader: reader).readHogModeOwner(for: 42) == owner)
    #expect(reader.reads == [query])
  }

  @Test("A failed hog-mode read retains the unowned sentinel")
  func unavailableHogMode() {
    var failures: [any Error] = []
    let inspector = AudioDeviceInspector(
      reader: CompatInspectorPropertyReader(), onFailure: { failures.append($0) })
    #expect(inspector.readHogModeOwner(for: 42) == -1)
    #expect((failures.first as? CompatInspectorPropertyReader.ReadError) == .unavailable)
    #expect(failures.count == 1)
  }

  @Test("Physical format reads the first output stream in global stream scope")
  func physicalFormat() throws {
    let reader = CompatInspectorPropertyReader()
    let streams = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    let format = CompatInspectorPropertyQuery(
      object: 90, selector: kAudioStreamPropertyPhysicalFormat,
      scope: kAudioObjectPropertyScopeGlobal)
    reader.values[streams] = [AudioStreamID(90), AudioStreamID(91)]
    var expected = AudioStreamBasicDescription()
    expected.mSampleRate = 48_000
    expected.mChannelsPerFrame = 2
    reader.values[format] = expected

    let result = try #require(AudioDeviceInspector(reader: reader).readPhysicalFormat(for: 42))

    #expect(result.mSampleRate == expected.mSampleRate)
    #expect(result.mChannelsPerFrame == expected.mChannelsPerFrame)
    #expect(reader.reads == [streams, format])
  }

  @Test("A device without streams has no physical format")
  func physicalFormatWithoutStreams() {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    reader.values[query] = [AudioStreamID]()
    var failures: [any Error] = []
    let inspector = AudioDeviceInspector(reader: reader, onFailure: { failures.append($0) })
    #expect(inspector.readPhysicalFormat(for: 42) == nil)
    #expect(reader.reads == [query])
    #expect(failures.isEmpty)
  }

  @Test("Stream-list or physical-format read failures return no format", arguments: [false, true])
  func unavailablePhysicalFormat(hasStreams: Bool) {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    if hasStreams { reader.values[query] = [AudioStreamID(90)] }
    var failures: [any Error] = []
    let inspector = AudioDeviceInspector(reader: reader, onFailure: { failures.append($0) })
    #expect(inspector.readPhysicalFormat(for: 42) == nil)
    #expect((failures.first as? CompatInspectorPropertyReader.ReadError) == .unavailable)
    #expect(failures.count == 1)
    #expect(reader.reads.first == query)
    #expect(reader.reads.count == (hasStreams ? 2 : 1))
  }

  @Test("Unknown selectors return false without querying settable state")
  func settableRobustness() {
    let reader = CompatInspectorPropertyReader()
    let selector = AudioObjectPropertySelector(0x7A7A_7A7A)
    #expect(!AudioDeviceInspector(reader: reader).isPropertySettable(selector, for: 42))
    #expect(
      reader.existenceChecks == [
        CompatInspectorPropertyQuery(
          object: 42, selector: selector, scope: kAudioObjectPropertyScopeOutput)
      ])
    #expect(reader.settableChecks.isEmpty)
  }

  @Test(
    "Known property settable state is returned without inventing a capability",
    arguments: [false, true])
  func settableRealSelector(writable: Bool) {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyNominalSampleRate,
      scope: kAudioObjectPropertyScopeOutput)
    reader.present.insert(query)
    reader.writable[query] = writable
    #expect(
      AudioDeviceInspector(reader: reader).isPropertySettable(query.selector, for: 42) == writable)
    #expect(reader.existenceChecks == [query])
    #expect(reader.settableChecks == [query])
  }

  @Test("Failed settable queries do not claim write capability")
  func unavailableSettableProperty() {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyNominalSampleRate,
      scope: kAudioObjectPropertyScopeOutput)
    reader.present.insert(query)
    var failures: [any Error] = []
    let inspector = AudioDeviceInspector(reader: reader, onFailure: { failures.append($0) })
    #expect(!inspector.isPropertySettable(query.selector, for: 42))
    #expect(reader.settableChecks == [query])
    #expect((failures.first as? CompatInspectorPropertyReader.ReadError) == .unavailable)
    #expect(failures.count == 1)
  }

  @Test(
    "Explicit scopes are forwarded to both property checks",
    arguments: [
      kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeInput,
      kAudioObjectPropertyScopeOutput,
    ])
  func explicitPropertyScope(scope: AudioObjectPropertyScope) {
    let reader = CompatInspectorPropertyReader()
    let query = CompatInspectorPropertyQuery(
      object: 42, selector: kAudioDevicePropertyNominalSampleRate, scope: scope)
    reader.present.insert(query)
    reader.writable[query] = true
    #expect(
      AudioDeviceInspector(reader: reader).isPropertySettable(query.selector, for: 42, scope: scope)
    )
    #expect(reader.existenceChecks == [query])
    #expect(reader.settableChecks == [query])
  }
}

@Suite("Compat: ProcessNameLookup")
struct UpstreamProcessNameLookupTests {
  @Test("returns a non-empty name for the current process")
  func currentProcess() {
    let name = ProcessNameLookup.name(for: getpid())
    #expect(name != nil)
    #expect(name?.isEmpty == false)
  }

  @Test("returns nil for PID 0")
  func pidZero() {
    #expect(ProcessNameLookup.name(for: 0) == nil)
  }

  @Test("returns nil for a negative PID")
  func negativePID() {
    #expect(ProcessNameLookup.name(for: -1) == nil)
  }

  @Test("returns nil for an improbably large PID")
  func bogusLargePID() {
    #expect(ProcessNameLookup.name(for: 999_999_999) == nil)
  }
}

@Suite("Compat: BT rate-change detection")
struct UpstreamBTCallModeTransitionTests {
  @Test("Fires on any change to a different valid rate")
  func firesOnChange() {
    #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 24_000))
    #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 48_000))
    #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 44_100, newRate: 48_000))
    #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 16_000))
    #expect(AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 0, newRate: 48_000))
  }

  @Test("Does not fire when the rate is unchanged")
  func noFireOnSameRate() {
    #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 48_000))
    #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 24_000))
  }

  @Test("Transient/failed read (rate 0) never fires")
  func transientZeroNeverFires() {
    #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 48_000, newRate: 0))
    #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 24_000, newRate: 0))
    #expect(!AudioDeviceMonitor.isMeaningfulRateChange(oldRate: 0, newRate: 0))
  }
}
