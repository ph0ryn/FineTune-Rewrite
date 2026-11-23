import AppKit
import AudioToolbox

struct AudioObservationTarget: Hashable {
  let object: AudioObjectID
  let selector: AudioObjectPropertySelector
  let scope: AudioObjectPropertyScope
  init(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) {
    self.object = object
    self.selector = selector
    self.scope = scope
  }
}

struct AudioStreamRecord {
  let id: AudioStreamID
  let format: AudioStreamBasicDescription
}

struct AudioDeviceRecord {
  let device: AudioDevice
  let outputStreams: [AudioStreamRecord]
  let inputStreams: [AudioStreamRecord]
  let sampleRate: Double?
}

struct AudioDeviceInventory {
  let devices: [AudioDeviceRecord]
  let observationTargets: Set<AudioObservationTarget>
}

struct AudioProcessRecord {
  let objectID: AudioObjectID
  let pid: pid_t
  let bundleID: String?
  let isRunning: Bool
}

struct ProcessApplicationMetadata {
  /// AppKit's documented -1 means this application has no OS process, not a HAL PID.
  let pid: pid_t
  let name: String?
  let bundleID: String?
  let icon: NSImage?
  let isApplication: Bool
}

@MainActor protocol AudioDeviceInventoryReading {
  func readDevices() throws -> AudioDeviceInventory
}

@MainActor protocol AudioProcessInventoryReading {
  func readProcesses() throws -> [AudioProcessRecord]
}

@MainActor protocol AudioProcessMetadataReading {
  func applications() throws -> [ProcessApplicationMetadata]
  func processName(for pid: pid_t) throws -> String?
  func parentPID(of pid: pid_t) throws -> pid_t?
  func responsiblePID(for pid: pid_t) -> pid_t?
}

@MainActor protocol AudioObservationScheduling {
  func schedule(
    every interval: Duration, tick: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) -> DevicePropertyObservation
}

/// A cancellable owner for the existing injectable monotonic clock; no work before schedule.
@MainActor struct ContinuousAudioObservationClock: AudioObservationScheduling {
  let clock: DeviceBackendClock
  init(clock: DeviceBackendClock = .continuous) { self.clock = clock }

  func schedule(
    every interval: Duration, tick: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) -> DevicePropertyObservation {
    let task = Task { @MainActor in
      while !Task.isCancelled {
        do { try await clock.sleep(interval) } catch is CancellationError { return } catch {
          tick(.failure(error))
          return
        }
        guard !Task.isCancelled else { return }
        tick(.success(()))
      }
    }
    return DevicePropertyObservation { task.cancel() }
  }
}

/// Registers additions transactionally, so a failed registration cannot discard the old observers.
@MainActor final class AudioObservationSubscriptions {
  private let observer: any AudioDevicePropertyObserving
  private var tokens: [AudioObservationTarget: DevicePropertyObservation] = [:]
  init(observer: any AudioDevicePropertyObserving) { self.observer = observer }

  func sync(
    _ targets: Set<AudioObservationTarget>, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws {
    var additions: [AudioObservationTarget: DevicePropertyObservation] = [:]
    do {
      for target in targets where tokens[target] == nil {
        additions[target] = try observer.observe(
          target.object, selector: target.selector, scope: target.scope, onChange: onChange)
      }
    } catch {
      for token in additions.values { token.cancel() }
      throw error
    }
    for target in Array(tokens.keys) where !targets.contains(target) {
      tokens.removeValue(forKey: target)?.cancel()
    }
    tokens.merge(additions) { current, _ in current }
  }

  func cancel() {
    for token in tokens.values { token.cancel() }
    tokens.removeAll()
  }
}
