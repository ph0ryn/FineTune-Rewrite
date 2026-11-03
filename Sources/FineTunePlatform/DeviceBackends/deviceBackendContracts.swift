import AudioToolbox
import Foundation
import OSLog

public enum DeviceBackendError: Error, Equatable, Sendable, LocalizedError {
  case unsupported(String)
  case unavailableDevice(String)
  case invalidVolume(Float)
  case osStatus(OSStatus)
  case operationFailed(String)
  case ambiguousDisplay(String)

  public var errorDescription: String? {
    switch self {
    case .unsupported(let operation): "\(operation) is not supported by this device."
    case .unavailableDevice(let uid): "The selected device is unavailable (\(uid))."
    case .invalidVolume: "Volume must be a finite value between zero and one."
    case .osStatus(let status): "The device operation failed (OSStatus \(status))."
    case .operationFailed(let message): message
    case .ambiguousDisplay(let name): "Cannot identify the display for \(name) unambiguously."
    }
  }
}

/// The existing reader and this writer are the only HAL property boundary used by the backends.
@MainActor
public protocol AudioDevicePropertyWriting {
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, value: Value
  ) throws
}

public struct CoreAudioDevicePropertyWriter: AudioDevicePropertyWriting {
  public init() {}

  public func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, value: Value
  ) throws {
    try AudioProperties.write(object, selector, scope: scope, value: value)
  }
}

/// Cancellation owns one listener registration and is idempotent, including deinitialization.
@MainActor
public final class DevicePropertyObservation {
  private var cancellation: (() -> Void)?

  public init(cancel: @escaping () -> Void) { cancellation = cancel }

  public func cancel() {
    let action = cancellation
    cancellation = nil
    action?()
  }

  isolated deinit { cancellation?() }
}

@MainActor
public protocol AudioDevicePropertyObserving {
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation
}

public struct CoreAudioDevicePropertyObserver: AudioDevicePropertyObserving {
  public init() {}

  public func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    var address = AudioProperties.address(selector, scope: scope)
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      Task { @MainActor in onChange() }
    }
    let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
    guard status == noErr else { throw DeviceBackendError.osStatus(status) }
    let storedAddress = address
    return DevicePropertyObservation {
      var address = storedAddress
      let status = AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
      if status != noErr {
        Logger(subsystem: "com.finetune-rewrite", category: "DeviceObservation")
          .error("Unable to remove device listener: \(status)")
      }
    }
  }
}

/// A monotonic delay, injectable without exposing a second scheduler or a test-only mode.
public struct DeviceBackendClock: Sendable {
  public let sleep: @Sendable (Duration) async throws -> Void

  public init(sleep: @escaping @Sendable (Duration) async throws -> Void) { self.sleep = sleep }

  public static var continuous: Self { Self { try await Task.sleep(for: $0) } }
}

public struct DDCVolumeState: Equatable, Sendable {
  public var observedPercent: Int?
  public var requestedPercent: Int?
  public var isMuted: Bool
  public var isApplying: Bool
  public var error: String?

  public init(
    observedPercent: Int?, requestedPercent: Int?, isMuted: Bool, isApplying: Bool,
    error: String?
  ) {
    self.observedPercent = observedPercent
    self.requestedPercent = requestedPercent
    self.isMuted = isMuted
    self.isApplying = isApplying
    self.error = error
  }

  /// Display intent while a write is pending; this is not an acknowledgement from the display.
  public var displayedVolume: Float? {
    (requestedPercent ?? observedPercent).map { Float($0) / 100 }
  }
}

/// Narrow dependency of the existing CoreAudioDeviceVolumeAdapter; it remains the output SoT.
@MainActor
public protocol DDCVolumeControlling: AnyObject {
  var states: [String: DDCVolumeState] { get }
  var lastError: (any Error)? { get }
  var onChange: (() -> Void)? { get set }
  func requestVolume(forUID uid: String, to volume: Float) throws
  func requestMute(forUID uid: String, to muted: Bool) throws
}
