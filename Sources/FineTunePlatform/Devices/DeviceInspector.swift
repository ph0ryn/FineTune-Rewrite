import AudioToolbox
import Darwin
import Foundation
import OSLog

/// The small read-only HAL seam used by device inspection, not by the audio callback.
public protocol AudioDevicePropertyReading {
  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value
  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value]
  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool
}

public struct CoreAudioDevicePropertyReader: AudioDevicePropertyReading {
  public init() {}

  public func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> Value {
    try AudioProperties.read(object, selector, scope: scope, initial: initial)
  }

  public func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, initial: Value
  ) throws -> [Value] {
    try AudioProperties.array(object, selector, scope: scope, initial: initial)
  }

  public func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) -> Bool {
    var address = AudioProperties.address(selector, scope: scope)
    return AudioObjectHasProperty(object, &address)
  }

  public func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
  ) throws -> Bool {
    var address = AudioProperties.address(selector, scope: scope)
    var settable: DarwinBoolean = false
    let status = AudioObjectIsPropertySettable(object, &address, &settable)
    guard status == noErr else { throw AudioProperties.error(status) }
    return settable.boolValue
  }
}

/// Unavailable metadata has conservative values; failed reads are also reported, never invented.
public struct AudioDeviceInspector {
  private let reader: any AudioDevicePropertyReading
  private let onFailure: (any Error) -> Void

  public init(
    reader: any AudioDevicePropertyReading = CoreAudioDevicePropertyReader(),
    onFailure: ((any Error) -> Void)? = nil
  ) {
    self.reader = reader
    self.onFailure =
      onFailure ?? { error in
        Logger(subsystem: "com.finetune-rewrite", category: "DeviceInspector")
          .error("Device property read failed: \(String(describing: error), privacy: .public)")
      }
  }

  public func readPhysicalFormat(
    for device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
  ) -> AudioStreamBasicDescription? {
    do {
      let streams = try reader.readArray(
        device, selector: kAudioDevicePropertyStreams, scope: scope, initial: AudioStreamID.unknown
      )
      guard let stream = streams.first, stream.isValid else { return nil }
      return try reader.readScalar(
        stream, selector: kAudioStreamPropertyPhysicalFormat,
        scope: kAudioObjectPropertyScopeGlobal, initial: AudioStreamBasicDescription()
      )
    } catch {
      onFailure(error)
      return nil
    }
  }

  public func readAvailableSampleRates(
    for device: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [Double] {
    do {
      let ranges = try reader.readArray(
        device, selector: kAudioDevicePropertyAvailableNominalSampleRates, scope: scope,
        initial: AudioValueRange()
      )
      return ranges.flatMap { range in
        range.mMinimum == range.mMaximum ? [range.mMinimum] : [range.mMinimum, range.mMaximum]
      }
    } catch {
      onFailure(error)
      return []
    }
  }

  public func readHogModeOwner(for device: AudioDeviceID) -> pid_t {
    do {
      return try reader.readScalar(
        device, selector: kAudioDevicePropertyHogMode, scope: kAudioObjectPropertyScopeGlobal,
        initial: pid_t(-1)
      )
    } catch {
      onFailure(error)
      return -1
    }
  }

  public func isPropertySettable(
    _ selector: AudioObjectPropertySelector, for device: AudioDeviceID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
  ) -> Bool {
    guard reader.hasProperty(device, selector: selector, scope: scope) else { return false }
    do {
      return try reader.isPropertySettable(device, selector: selector, scope: scope)
    } catch {
      onFailure(error)
      return false
    }
  }
}

extension AudioDeviceID {
  public enum InspectorError: Error { case writeFailed(OSStatus) }

  public func readPhysicalFormat(
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
  ) -> AudioStreamBasicDescription? {
    AudioDeviceInspector().readPhysicalFormat(for: self, scope: scope)
  }

  public func readAvailableSampleRates(
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [Double] {
    AudioDeviceInspector().readAvailableSampleRates(for: self, scope: scope)
  }

  public func readHogModeOwner() -> pid_t { AudioDeviceInspector().readHogModeOwner(for: self) }

  public func isPropertySettable(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
  ) -> Bool {
    AudioDeviceInspector().isPropertySettable(selector, for: self, scope: scope)
  }

  /// Only an explicit user action should call this method. Inspection and tests never write rates.
  public func writeNominalSampleRate(
    _ rate: Double, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws {
    do {
      try AudioProperties.write(
        self, kAudioDevicePropertyNominalSampleRate, scope: scope, value: rate)
    } catch let error as NSError {
      throw InspectorError.writeFailed(OSStatus(error.code))
    }
  }
}

public enum ProcessNameLookup {
  public static func name(for pid: pid_t) -> String? {
    guard pid > 0 else { return nil }
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var selector: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&selector, UInt32(selector.count), &process, &size, nil, 0) == 0, size > 0 else {
      return nil
    }
    let name = withUnsafePointer(to: &process.kp_proc.p_comm) {
      String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
    }
    return name.isEmpty ? nil : name
  }
}
