import AppKit
import AudioToolbox

private struct StreamFormatFingerprint: Equatable {
  let rate: Double
  let format: AudioFormatID
  let flags: AudioFormatFlags
  let bytesPerPacket: UInt32
  let framesPerPacket: UInt32
  let bytesPerFrame: UInt32
  let channels: UInt32
  let bits: UInt32

  init(_ value: AudioStreamBasicDescription) {
    rate = value.mSampleRate
    format = value.mFormatID
    flags = value.mFormatFlags
    bytesPerPacket = value.mBytesPerPacket
    framesPerPacket = value.mFramesPerPacket
    bytesPerFrame = value.mBytesPerFrame
    channels = value.mChannelsPerFrame
    bits = value.mBitsPerChannel
  }
}

struct DeviceObservationProjection {
  private struct Key: Hashable {
    let uid: String
    let input: Bool
  }
  private struct Format: Equatable {
    let rate: Double
    let streams: [StreamFormatFingerprint]
  }
  private struct Binding: Equatable {
    let id: AudioDeviceID
    let streamIDs: [AudioStreamID]
    let format: Format
  }
  private struct Entry {
    let binding: Binding
    let bindingRevision: UInt64
    let formatRevision: UInt64
  }
  private var entries: [Key: Entry] = [:]
  private var bindingCounter: UInt64 = 0
  private var formatCounter: UInt64 = 0

  mutating func project(_ records: [AudioDeviceRecord]) throws -> (
    outputs: [AudioDevice], inputs: [AudioDevice]
  ) {
    var next: [Key: Entry] = [:]
    var outputs: [AudioDevice] = []
    var inputs: [AudioDevice] = []
    for record in records {
      guard record.device.id.isValid, !record.device.uid.isEmpty else {
        throw AudioObservationFailure(message: "Invalid audio device binding.")
      }
      for input in [false, true] {
        let streams = input ? record.inputStreams : record.outputStreams
        guard !streams.isEmpty else { continue }
        guard let rate = record.sampleRate, rate.isFinite, rate > 0 else {
          throw AudioObservationFailure(message: "Invalid device sample rate.")
        }
        let ordered = streams.sorted { $0.id < $1.id }
        guard Set(ordered.map(\.id)).count == ordered.count else {
          throw AudioObservationFailure(message: "Duplicate audio stream bindings.")
        }
        let format = Format(rate: rate, streams: ordered.map { StreamFormatFingerprint($0.format) })
        let binding = Binding(id: record.device.id, streamIDs: ordered.map(\.id), format: format)
        let key = Key(uid: record.device.uid, input: input)
        guard next[key] == nil else {
          throw AudioObservationFailure(message: "Duplicate device UID in one stream role.")
        }
        let previous = entries[key]
        let bindingRevision: UInt64
        if let previous, previous.binding == binding {
          bindingRevision = previous.bindingRevision
        } else {
          bindingCounter += 1
          bindingRevision = bindingCounter
        }
        let formatRevision: UInt64
        if let previous, previous.binding.format == format {
          formatRevision = previous.formatRevision
        } else {
          formatCounter += 1
          formatRevision = formatCounter
        }
        next[key] = Entry(
          binding: binding, bindingRevision: bindingRevision, formatRevision: formatRevision)
        let source = record.device
        let value = AudioDevice(
          id: source.id, uid: source.uid, name: source.name, icon: source.icon,
          supportsAutoEQ: input ? false : source.supportsAutoEQ, bindingRevision: bindingRevision,
          formatRevision: formatRevision, transportType: source.transportType)
        if input { inputs.append(value) } else { outputs.append(value) }
      }
    }
    entries = next
    return (
      outputs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
      inputs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    )
  }
}

@MainActor
struct ProcessObservationProjection {
  private var counter: UInt64 = 0
  mutating func project(_ grouped: [AudioApp], previous: [AudioApp]) -> [AudioApp] {
    grouped.map { app in
      let old = previous.first { $0.id == app.id }
      // AppKit metadata can briefly lose a bundle ID. The process identity is the live PID plus its
      // HAL objects, so reuse the last confirmed bundle ID for that same owner: changing the
      // persistence identifier here would stop and rebuild every route of a healthy app.
      let bundleID: String? = {
        guard app.bundleID == nil, let old, old.name == app.name, let confirmed = old.bundleID,
          !confirmed.isEmpty,
          !Set(old.processObjectIDs).isDisjoint(with: app.processObjectIDs)
        else { return app.bundleID }
        return confirmed
      }()
      let identifier = bundleID ?? "name:\(app.name)"
      let revision: UInt64
      if let old, old.processRevision > 0, old.persistenceIdentifier == identifier,
        old.processObjectIDs == app.processObjectIDs
      {
        revision = old.processRevision
      } else {
        counter += 1
        revision = counter
      }
      return AudioApp(
        id: app.id, processObjectIDs: app.processObjectIDs, name: app.name, icon: app.icon,
        bundleID: bundleID, isHelperBacked: app.isHelperBacked, processRevision: revision)
    }
  }
}

func sameDeviceObservation(_ old: [AudioDevice], _ new: [AudioDevice]) -> Bool {
  guard old.count == new.count else { return false }
  return zip(old, new).allSatisfy {
    $0.id == $1.id && $0.uid == $1.uid && $0.name == $1.name && $0.icon === $1.icon
      && $0.supportsAutoEQ == $1.supportsAutoEQ && $0.bindingRevision == $1.bindingRevision
      && $0.formatRevision == $1.formatRevision && $0.transportType == $1.transportType
  }
}

func sameProcessObservation(_ old: [AudioApp], _ new: [AudioApp]) -> Bool {
  guard old.count == new.count else { return false }
  return zip(old, new).allSatisfy {
    $0.id == $1.id && $0.processObjectIDs == $1.processObjectIDs && $0.name == $1.name
      && $0.icon === $1.icon && $0.bundleID == $1.bundleID && $0.isHelperBacked == $1.isHelperBacked
      && $0.processRevision == $1.processRevision
  }
}
