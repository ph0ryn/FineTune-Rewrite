import AudioToolbox
import FineTuneDomain
import Foundation

/// Explicit read-only inventory acquisition. No HAL calls or registrations in its initializer.
@MainActor
struct CoreAudioObservationInventory: AudioDeviceInventoryReading, AudioProcessInventoryReading {
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
    let ids: [AudioDeviceID] = try AudioProperties.array(
      .system, kAudioHardwarePropertyDevices, initial: .unknown)
    var targets: Set<AudioObservationTarget> = [
      .init(object: .system, selector: kAudioHardwarePropertyDevices)
    ]
    var records: [AudioDeviceRecord] = []
    for id in Set(ids).sorted() {
      let uid = try id.readDeviceUID()
      let name = try id.readDeviceName()
      guard !uid.isEmpty, !name.isEmpty else {
        throw AudioObservationFailure(message: "An audio device returned empty identity metadata.")
      }
      let output = try streams(id, scope: kAudioObjectPropertyScopeOutput)
      let input = try streams(id, scope: kAudioObjectPropertyScopeInput)
      let rate: Double? = output.isEmpty && input.isEmpty ? nil : try id.readNominalSampleRate()
      if let rate, !rate.isFinite || rate <= 0 {
        throw AudioObservationFailure(
          message: "The device \(uid) returned an invalid nominal sample rate.")
      }
      let source = AudioObservationTarget(
        object: id, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput
      )
      let dataSource: UInt32? =
        supports(source)
        ? try AudioProperties.read(id, source.selector, scope: source.scope, initial: UInt32(0))
        : nil
      let transportCode = try AudioProperties.read(
        id, kAudioDevicePropertyTransportType, initial: UInt32(0))
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
      targets.formUnion(deviceTargets.filter(supports))
      for stream in output + input {
        targets.insert(.init(object: stream.id, selector: kAudioStreamPropertyPhysicalFormat))
      }
    }
    return AudioDeviceInventory(devices: records, observationTargets: targets)
  }

  private func streams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws
    -> [AudioStreamRecord]
  {
    let ids: [AudioStreamID] = try AudioProperties.array(
      device, kAudioDevicePropertyStreams, scope: scope, initial: .unknown)
    return try Set(ids).sorted().map { stream in
      let format = try AudioProperties.read(
        stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
      guard format.mSampleRate.isFinite, format.mSampleRate > 0 else {
        throw AudioObservationFailure(
          message: "An audio stream returned an invalid physical format.")
      }
      return AudioStreamRecord(id: stream, format: format)
    }
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
