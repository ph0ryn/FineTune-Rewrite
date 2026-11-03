import Foundation

/// Discovery health is not an audio-capture authorization result.
public enum AudioObservationHealth: Equatable, Sendable {
  case notStarted
  case healthy
  case failed(String)
}

public struct AudioDeviceObservationSnapshot {
  public let outputDevices: [AudioDevice]
  public let inputDevices: [AudioDevice]
  public let health: AudioObservationHealth
  public let revision: UInt64

  public init(
    outputDevices: [AudioDevice] = [], inputDevices: [AudioDevice] = [],
    health: AudioObservationHealth = .notStarted, revision: UInt64 = 0
  ) {
    self.outputDevices = outputDevices
    self.inputDevices = inputDevices
    self.health = health
    self.revision = revision
  }
}

public struct AudioProcessObservationSnapshot {
  public let activeApps: [AudioApp]
  public let health: AudioObservationHealth
  public let revision: UInt64

  public init(
    activeApps: [AudioApp] = [], health: AudioObservationHealth = .notStarted, revision: UInt64 = 0
  ) {
    self.activeApps = activeApps
    self.health = health
    self.revision = revision
  }
}

@MainActor
public protocol AudioDeviceObservationProviding: AudioDeviceProviding {
  var observation: AudioDeviceObservationSnapshot { get }
  var onObservationChanged: (() -> Void)? { get set }
}

@MainActor
public protocol AudioProcessObservationProviding: AudioProcessMonitoring {
  var observation: AudioProcessObservationSnapshot { get }
  var onObservationChanged: (() -> Void)? { get set }
  func resolveApp(identifier: String, processRevision: UInt64) throws -> AudioApp
}

public enum AudioAppObservationResolutionError: Error, Equatable {
  case unavailable(String)
  case bindingChanged(String)
}

extension AudioProcessObservationProviding {
  public func resolveApp(identifier: String, processRevision: UInt64) throws -> AudioApp {
    guard observation.health == .healthy else {
      throw AudioAppObservationResolutionError.unavailable(identifier)
    }
    let matches = observation.activeApps.filter { $0.persistenceIdentifier == identifier }
    guard !matches.isEmpty else { throw AudioAppObservationResolutionError.unavailable(identifier) }
    guard processRevision > 0,
      let app = matches.first(where: { $0.processRevision == processRevision })
    else { throw AudioAppObservationResolutionError.bindingChanged(identifier) }
    return app
  }
}

struct AudioObservationFailure: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

extension AudioObservationHealth {
  var error: (any Error)? {
    if case .failed(let reason) = self { AudioObservationFailure(message: reason) } else { nil }
  }
}
