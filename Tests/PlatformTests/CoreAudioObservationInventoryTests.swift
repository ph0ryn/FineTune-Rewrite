import AudioToolbox
import FineTuneDomain
import Foundation
import Testing

@testable import FineTunePlatform

@Suite("CoreAudio user-device inventory")
@MainActor
struct CoreAudioObservationInventoryTests {
  @Test("Only private aggregates disappear, regardless of display name", arguments: [false, true])
  func privateRoutesAreNotUserDevices(input: Bool) {
    let reader = InventoryPropertyReader(input: input)
    let observer = ObservationTestObserver()
    let monitor = AudioDeviceMonitor(
      inventory: CoreAudioObservationInventory(reader: reader), observer: observer)
    monitor.start()
    defer { monitor.stop() }

    let devices = input ? monitor.inputDevices : monitor.outputDevices
    #expect(Set(devices.map(\.uid)) == ["fixture-11", "fixture-12", "fixture-15"])
    #expect(monitor.observation.health == .healthy)
    #expect(devices.contains { $0.name == "FineTune Process Route" && $0.id == 12 })
    #expect(devices.contains { $0.id == 11 && $0.transportType == .usb })
    #expect(devices.contains { $0.id == 12 && $0.transportType == .aggregate })
    #expect(devices.contains { $0.id == 15 })  // SDK: absent private key means published.
    #expect((input ? monitor.outputDevices : monitor.inputDevices).isEmpty)
    #expect(
      observer.registrations.contains {
        $0.object == .system && $0.selector == kAudioHardwarePropertyDevices
      })
    #expect(!observer.registrations.contains { [13, 14, 131, 141].contains($0.object) })
  }

  @Test("Stream physical and virtual formats are both observed", arguments: [false, true])
  func streamFormatObservations(input: Bool) {
    let reader = InventoryPropertyReader(input: input)
    let observer = ObservationTestObserver()
    let monitor = AudioDeviceMonitor(
      inventory: CoreAudioObservationInventory(reader: reader), observer: observer)
    monitor.start()
    defer { monitor.stop() }
    #expect(
      observer.registrations.contains {
        $0.object == 111 && $0.selector == kAudioStreamPropertyPhysicalFormat
      })
    #expect(
      observer.registrations.contains {
        $0.object == 111 && $0.selector == kAudioStreamPropertyVirtualFormat
      })
  }

  @Test(
    "Private children need no identity, stream or observer acquisition", arguments: [false, true])
  func privateMetadataIsNotRequired(input: Bool) {
    let reader = InventoryPropertyReader(input: input)
    reader.denyPrivateMetadata = true
    let observer = ObservationTestObserver()
    let monitor = AudioDeviceMonitor(
      inventory: CoreAudioObservationInventory(reader: reader), observer: observer)
    monitor.start()
    defer { monitor.stop() }

    #expect(monitor.observation.health == .healthy)
    let devices = input ? monitor.inputDevices : monitor.outputDevices
    #expect(Set(devices.map(\.uid)) == ["fixture-11", "fixture-12", "fixture-15"])
    #expect(!observer.registrations.contains { [13, 14, 131, 141].contains($0.object) })
  }

  @Test(
    "Visibility failures are failed discovery, never a public-device default",
    arguments: InventoryVisibility.invalid)
  private func malformedVisibilityRetainsLastGoodInventory(visibility: InventoryVisibility) {
    let reader = InventoryPropertyReader(input: false)
    reader.devices = [reader.devices[0]]
    let monitor = AudioDeviceMonitor(
      inventory: CoreAudioObservationInventory(reader: reader), observer: ObservationTestObserver())
    monitor.refresh()
    #expect(monitor.observation.health == .healthy)
    #expect(monitor.outputDevices.map(\.uid) == ["fixture-11"])
    reader.devices.append(
      .init(
        id: 12, name: "A public-looking name", aggregate: true,
        visibility: visibility, input: false))
    monitor.refresh()

    if case .failed = monitor.observation.health {
    } else {
      Issue.record("Invalid or unreadable aggregate visibility was treated as public.")
    }
    #expect(monitor.lastError != nil)
    #expect(monitor.outputDevices.map(\.uid) == ["fixture-11"])
  }
}

nonisolated private enum InventoryVisibility: Equatable, Sendable {
  case published, privateRoute, absent, readFailure, classFailure, nilObject, wrongObject
  case stringFlag, booleanFlag, fraction, negative, outsideRange, nonfinite

  static let invalid: [Self] = [
    .readFailure, .classFailure, .nilObject, .wrongObject, .stringFlag, .booleanFlag,
    .fraction, .negative, .outsideRange, .nonfinite,
  ]

  func composition() throws -> CFTypeRef? {
    let key = kAudioAggregateDeviceIsPrivateKey
    switch self {
    case .published: return [key: NSNumber(value: 0)] as CFDictionary
    case .privateRoute: return [key: NSNumber(value: 1)] as CFDictionary
    case .absent: return [String: NSNumber]() as CFDictionary
    case .readFailure, .classFailure: throw InventoryPropertyReader.injectedFailure
    case .nilObject: return nil
    case .wrongObject: return "not a composition" as CFString
    case .stringFlag: return [key: "1"] as CFDictionary
    case .booleanFlag: return [key: NSNumber(value: true)] as CFDictionary
    case .fraction: return [key: NSNumber(value: 0.5)] as CFDictionary
    case .negative: return [key: NSNumber(value: -1)] as CFDictionary
    case .outsideRange: return [key: NSNumber(value: 2)] as CFDictionary
    case .nonfinite: return [key: NSNumber(value: Double.nan)] as CFDictionary
    }
  }
}

// Each composition dictionary is created for that read and transferred to production.
// The fake does not retain a source dictionary to mask borrowed-value lifetime bugs.
nonisolated private final class InventoryPropertyReader: AudioDevicePropertyReading {
  struct Device {
    let id: AudioDeviceID
    let name: String
    let aggregate: Bool
    let visibility: InventoryVisibility
    let input: Bool
    var stream: AudioStreamID { id * 10 + 1 }
  }

  var devices: [Device]
  var denyPrivateMetadata = false
  static var injectedFailure: NSError {
    NSError(domain: NSOSStatusErrorDomain, code: -7821)
  }

  init(input: Bool) {
    devices = [
      .init(
        id: 11, name: "FineTune Process Route", aggregate: false,
        visibility: .published, input: input),
      .init(
        id: 12, name: "FineTune Process Route", aggregate: true,
        visibility: .published, input: input),
      .init(
        id: 13, name: "Unrelated internal name", aggregate: true,
        visibility: .privateRoute, input: input),
      .init(
        id: 14, name: "FineTune Process Route", aggregate: true,
        visibility: .privateRoute, input: input),
      .init(
        id: 15, name: "User Aggregate", aggregate: true,
        visibility: .absent, input: input),
    ]
  }

  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value {
    if selector == kAudioStreamPropertyPhysicalFormat,
      devices.contains(where: { $0.stream == object })
    {
      var format = AudioStreamBasicDescription()
      format.mSampleRate = 48_000
      format.mFormatID = kAudioFormatLinearPCM
      format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
      format.mChannelsPerFrame = 2
      format.mBitsPerChannel = 32
      format.mBytesPerFrame = 8
      format.mFramesPerPacket = 1
      format.mBytesPerPacket = 8
      return try typed(format)
    }
    guard let device = devices.first(where: { $0.id == object }) else {
      throw Self.injectedFailure
    }
    if denyPrivateMetadata, device.visibility == .privateRoute,
      selector != kAudioObjectPropertyClass,
      selector != kAudioAggregateDevicePropertyComposition
    {
      throw Self.injectedFailure
    }
    switch selector {
    case kAudioObjectPropertyClass:
      if device.visibility == .classFailure { throw Self.injectedFailure }
      return try typed(
        UInt32(device.aggregate ? kAudioAggregateDeviceClassID : kAudioDeviceClassID))
    case kAudioDevicePropertyDeviceUID:
      return try retained("fixture-\(device.id)" as CFString)
    case kAudioObjectPropertyName:
      return try retained(device.name as CFString)
    case kAudioDevicePropertyNominalSampleRate:
      return try typed(Double(48_000))
    case kAudioDevicePropertyTransportType:
      return try typed(
        UInt32(
          device.aggregate ? kAudioDeviceTransportTypeAggregate : kAudioDeviceTransportTypeUSB))
    case kAudioAggregateDevicePropertyComposition:
      return try retained(device.visibility.composition())
    default: throw Self.injectedFailure
    }
  }

  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value] {
    if object == .system, selector == kAudioHardwarePropertyDevices {
      return try typed(devices.map(\.id))
    }
    guard selector == kAudioDevicePropertyStreams,
      let device = devices.first(where: { $0.id == object })
    else {
      throw Self.injectedFailure
    }
    if denyPrivateMetadata, device.visibility == .privateRoute { throw Self.injectedFailure }
    let expected = device.input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    let streams: [AudioStreamID] = scope == expected ? [device.stream] : []
    return try typed(streams)
  }

  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    selector != kAudioDevicePropertyDataSource && devices.contains { $0.id == object }
  }

  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool { throw Self.injectedFailure }

  private func typed<Value>(_ value: Any) throws -> Value {
    guard let result = value as? Value else { throw Self.injectedFailure }
    return result
  }

  private func retained<Value>(_ object: CFTypeRef?) throws -> Value {
    let pointer = object.map { UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque()) }
    if let result = (pointer as Any) as? Value { return result }
    if let pointer { Unmanaged<CFTypeRef>.fromOpaque(pointer).release() }
    throw Self.injectedFailure
  }
}
