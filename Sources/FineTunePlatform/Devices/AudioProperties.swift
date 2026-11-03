import AudioToolbox
import FineTuneDomain
import Foundation

public enum AudioScope: Sendable {
  case global, input, output

  public var propertyScope: AudioObjectPropertyScope {
    switch self {
    case .global: kAudioObjectPropertyScopeGlobal
    case .input: kAudioObjectPropertyScopeInput
    case .output: kAudioObjectPropertyScopeOutput
    }
  }
}

/// Core Audio property access stays outside Control and Domain.
enum AudioProperties {
  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
    )
  }

  static func read<Value: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: Value
  ) throws -> Value {
    var property = address(selector, scope: scope)
    var value = initial
    var size = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    guard status == noErr else { throw error(status) }
    return value
  }

  static func array<Value: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: Value
  ) throws -> [Value] {
    var property = address(selector, scope: scope)
    var size: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
    guard sizeStatus == noErr else { throw error(sizeStatus) }
    let count = Int(size) / MemoryLayout<Value>.stride
    guard count > 0 else { return [] }
    var values = Array(repeating: initial, count: count)
    let status = values.withUnsafeMutableBufferPointer {
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw error(status) }
    return Array(values.prefix(Int(size) / MemoryLayout<Value>.stride))
  }

  static func string(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) throws -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
    }
    guard status == noErr else { throw error(status) }
    guard let value else { throw error(kAudioHardwareUnspecifiedError) }
    return value.takeRetainedValue() as String
  }

  static func write<Value: BitwiseCopyable>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: Value
  ) throws {
    var property = address(selector, scope: scope)
    var value = value
    let status = withUnsafePointer(to: &value) {
      AudioObjectSetPropertyData(object, &property, 0, nil, UInt32(MemoryLayout<Value>.size), $0)
    }
    guard status == noErr else { throw error(status) }
  }

  static func error(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
  }
}

extension AudioDeviceID {
  public func readDeviceName() throws -> String {
    try AudioProperties.string(self, kAudioObjectPropertyName)
  }

  public func readDeviceUID() throws -> String {
    try AudioProperties.string(self, kAudioDevicePropertyDeviceUID)
  }

  public func readNominalSampleRate() throws -> Float64 {
    try AudioProperties.read(self, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
  }

  public func readTransportType() -> TransportType {
    let code = try? AudioProperties.read(
      self, kAudioDevicePropertyTransportType, initial: UInt32(0))
    return code.map { TransportType(rawValue: $0) } ?? .unknown
  }

  public func readProcessIsRunning() -> Bool {
    let running = try? AudioProperties.read(
      self, kAudioProcessPropertyIsRunning, initial: UInt32(0))
    return running.map { $0 != 0 } ?? false
  }
}
