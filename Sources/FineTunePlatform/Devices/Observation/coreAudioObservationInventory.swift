import AudioToolbox
import FineTuneDomain
import Foundation

/// Explicit read-only inventory acquisition. No HAL calls or registrations in its initializer.
@MainActor
struct CoreAudioObservationInventory: AudioDeviceInventoryReading, AudioProcessInventoryReading {
  private let reader: any AudioDevicePropertyReading

  init(reader: any AudioDevicePropertyReading = CoreAudioDevicePropertyReader()) {
    self.reader = reader
  }

  func readProcesses() throws -> [AudioProcessRecord] {
    let ids: [AudioObjectID] = try AudioProperties.array(
      .system, kAudioHardwarePropertyProcessObjectList, initial: .unknown)
    var records: [AudioProcessRecord] = []
    for id in Set(ids).sorted() {
      do {
        let pid = try AudioProperties.read(id, kAudioProcessPropertyPID, initial: pid_t(0))
        let running = try AudioProperties.read(
          id, kAudioProcessPropertyIsRunning, initial: UInt32(0))
        let bundle = try optionalString(id, selector: kAudioProcessPropertyBundleID)
        records.append(
          AudioProcessRecord(objectID: id, pid: pid, bundleID: bundle, isRunning: running != 0))
      } catch {
        // A process can disappear between the global list and its fields. Other errors are not empty discovery.
        let failure = error as NSError
        if failure.domain == NSOSStatusErrorDomain,
          failure.code == Int(kAudioHardwareBadObjectError)
        {
          continue
        }
        throw error
      }
    }
    return records
  }

  func readDevices() throws -> AudioDeviceInventory {
    let ids: [AudioDeviceID] = try reader.readArray(
      .system, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal,
      initial: AudioDeviceID.unknown)
    var targets: Set<AudioObservationTarget> = [
      .init(object: .system, selector: kAudioHardwarePropertyDevices)
    ]
    var records: [AudioDeviceRecord] = []
    for id in Set(ids).sorted() {
      if try isPrivateAggregate(id) { continue }
      let uid = try string(id, selector: kAudioDevicePropertyDeviceUID)
      let name = try string(id, selector: kAudioObjectPropertyName)
      guard !uid.isEmpty, !name.isEmpty else {
        throw AudioObservationFailure(message: "An audio device returned empty identity metadata.")
      }
      let output = try streams(id, scope: kAudioObjectPropertyScopeOutput)
      let input = try streams(id, scope: kAudioObjectPropertyScopeInput)
      let rate: Double? =
        output.isEmpty && input.isEmpty
        ? nil
        : try reader.readScalar(
          id, selector: kAudioDevicePropertyNominalSampleRate,
          scope: kAudioObjectPropertyScopeGlobal, initial: Double(0))
      if let rate, !rate.isFinite || rate <= 0 {
        throw AudioObservationFailure(
          message: "The device \(uid) returned an invalid nominal sample rate.")
      }
      let source = AudioObservationTarget(
        object: id, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput
      )
      let dataSource: UInt32? =
        supportsDeviceProperty(source)
        ? try reader.readScalar(
          id, selector: source.selector, scope: source.scope, initial: UInt32(0))
        : nil
      let transportCode = try reader.readScalar(
        id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal,
        initial: UInt32(0))
      let transport = TransportType(rawValue: transportCode)
      let excluded = ["HomePod", "Apple TV", "Studio Display", "Pro Display XDR"].contains {
        name.localizedCaseInsensitiveContains($0)
      }
      let autoEQ: Bool
      switch transport {
      case .hdmi, .displayPort, .airPlay, .virtual: autoEQ = false
      case .builtIn: autoEQ = dataSource == 0x6864_706E
      default: autoEQ = !excluded
      }
      records.append(
        AudioDeviceRecord(
          device: AudioDevice(
            id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: autoEQ,
            transportType: transport),
          outputStreams: output, inputStreams: input, sampleRate: rate))
      let deviceTargets: [AudioObservationTarget] = [
        .init(object: id, selector: kAudioObjectPropertyName),
        .init(object: id, selector: kAudioDevicePropertyTransportType),
        .init(object: id, selector: kAudioDevicePropertyNominalSampleRate),
        .init(
          object: id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
        .init(
          object: id, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput),
        source,
      ]
      targets.formUnion(deviceTargets.filter(supportsDeviceProperty))
      for stream in output + input {
        targets.insert(.init(object: stream.id, selector: kAudioStreamPropertyPhysicalFormat))
        targets.insert(.init(object: stream.id, selector: kAudioStreamPropertyVirtualFormat))
      }
    }
    return AudioDeviceInventory(devices: records, observationTargets: targets)
  }

  private func streams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws
    -> [AudioStreamRecord]
  {
    let ids: [AudioStreamID] = try reader.readArray(
      device, selector: kAudioDevicePropertyStreams, scope: scope, initial: AudioStreamID.unknown)
    guard Set(ids).count == ids.count else {
      throw AudioObservationFailure(message: "Duplicate audio stream bindings.")
    }
    return try ids.map { stream in
      let format = try reader.readScalar(
        stream, selector: kAudioStreamPropertyPhysicalFormat,
        scope: kAudioObjectPropertyScopeGlobal, initial: AudioStreamBasicDescription())
      guard format.mSampleRate.isFinite, format.mSampleRate > 0 else {
        throw AudioObservationFailure(
          message: "An audio stream returned an invalid physical format.")
      }
      return AudioStreamRecord(id: stream, format: format)
    }
  }

  private func isPrivateAggregate(_ object: AudioDeviceID) throws -> Bool {
    let objectClass: AudioClassID = try reader.readScalar(
      object, selector: kAudioObjectPropertyClass, scope: kAudioObjectPropertyScopeGlobal,
      initial: AudioClassID(0))
    guard objectClass == kAudioAggregateDeviceClassID else { return false }
    let value = try ownedProperty(object, selector: kAudioAggregateDevicePropertyComposition)
    guard CFGetTypeID(value) == CFDictionaryGetTypeID() else {
      throw AudioProperties.error(kAudioHardwareIllegalOperationError)
    }
    let key = kAudioAggregateDeviceIsPrivateKey as CFString
    // Keep both owners alive through all borrowed-pointer type checks and number decoding.
    return try withExtendedLifetime((value, key)) {
      let composition = unsafeDowncast(value, to: CFDictionary.self)
      guard
        let pointer = CFDictionaryGetValue(composition, Unmanaged.passUnretained(key).toOpaque())
      else {
        // The SDK explicitly defines an absent private key as published system-wide.
        return false
      }
      let flag = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
      guard CFGetTypeID(flag) == CFNumberGetTypeID() else {
        throw AudioProperties.error(kAudioHardwareIllegalOperationError)
      }
      var observed: Double = 0
      guard CFNumberGetValue(unsafeDowncast(flag, to: CFNumber.self), .float64Type, &observed),
        observed == 0 || observed == 1
      else {
        throw AudioProperties.error(kAudioHardwareIllegalOperationError)
      }
      return observed == 1
    }
  }

  private func ownedProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector
  ) throws -> CFTypeRef {
    let pointer: UnsafeRawPointer? = try reader.readScalar(
      object, selector: selector, scope: kAudioObjectPropertyScopeGlobal,
      initial: Optional<UnsafeRawPointer>.none)
    guard let pointer else { throw AudioProperties.error(kAudioHardwareUnspecifiedError) }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
  }

  private func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws
    -> String
  {
    let value = try ownedProperty(object, selector: selector)
    guard CFGetTypeID(value) == CFStringGetTypeID() else {
      throw AudioProperties.error(kAudioHardwareIllegalOperationError)
    }
    return unsafeDowncast(value, to: CFString.self) as String
  }

  private func supportsDeviceProperty(_ target: AudioObservationTarget) -> Bool {
    reader.hasProperty(target.object, selector: target.selector, scope: target.scope)
  }

  private func supports(_ target: AudioObservationTarget) -> Bool {
    var address = AudioProperties.address(target.selector, scope: target.scope)
    return AudioObjectHasProperty(target.object, &address)
  }

  private func optionalString(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws
    -> String?
  {
    let target = AudioObservationTarget(object: object, selector: selector)
    guard supports(target) else { return nil }
    var address = AudioProperties.address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    guard status == noErr else { throw AudioProperties.error(status) }
    return value?.takeRetainedValue() as String?
  }
}
