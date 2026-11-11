import Foundation
import Observation

/// Alert volume is an OS-global percent, independent of device volume and persisted app settings.
@MainActor @Observable
public final class AlertVolumeBackend {
  public private(set) var observedVolume: Float?
  public private(set) var requestedVolume: Float?
  public private(set) var isApplying = false
  public private(set) var lastError: (any Error)?

  /// While pending, the UI may show intent with its applying indicator, not a false readback.
  public var displayedVolume: Float? { isApplying ? requestedVolume : observedVolume }

  private let scripts: any DeviceScriptRunning
  private let clock: DeviceBackendClock
  private let blockingScript: @Sendable (String) throws -> DeviceScriptResult
  private var generation: UInt64 = 0
  private var pendingWrite: Task<Void, any Error>?
  private static let readScript = "get alert volume of (get volume settings)"

  public init(
    scriptRunner: any DeviceScriptRunning, clock: DeviceBackendClock,
    blockingScript: @escaping @Sendable (String) throws -> DeviceScriptResult = {
      try SystemDeviceScriptRunner.runBlocking(script: $0)
    }
  ) {
    scripts = scriptRunner
    self.clock = clock
    self.blockingScript = blockingScript
  }

  /// The AppKit will-terminate turn cannot await or re-read; one blocking write restores silence.
  /// A failed restore keeps its persisted intent for the next launch.
  public func restoreForTermination(_ volume: Float) -> Bool {
    guard volume.isFinite, (0...1).contains(volume) else { return false }
    let percent = Int((volume * 100).rounded())
    do {
      let result = try blockingScript("set volume alert volume \(percent)")
      guard result.status == 0 else {
        lastError = DeviceBackendError.operationFailed(
          "Unable to restore the system alert volume (status \(result.status)): \(result.output)")
        return false
      }
      observedVolume = Float(percent) / 100
      requestedVolume = nil
      isApplying = false
      lastError = nil
      return true
    } catch {
      lastError = error
      return false
    }
  }

  public func refresh() async {
    guard !isApplying else { return }
    generation &+= 1
    let epoch = generation
    do {
      let percent = try await readPercent()
      guard generation == epoch, !isApplying else { return }
      observedVolume = Float(percent) / 100
      lastError = nil
    } catch {
      guard generation == epoch, !(error is CancellationError) else { return }
      lastError = error
    }
  }

  /// Each caller can await its own outcome; superseded and stopped requests throw cancellation.
  public func setVolume(_ volume: Float) async throws {
    try Task.checkCancellation()
    guard volume.isFinite, (0...1).contains(volume) else {
      let error = DeviceBackendError.invalidVolume(volume)
      lastError = error
      throw error
    }
    let percent = Int((volume * 100).rounded())
    let target = Float(percent) / 100
    if requestedVolume == target, lastError == nil {
      if let pendingWrite {
        try await pendingWrite.value
        return
      }
      if observedVolume == target { return }
    }
    generation &+= 1
    let epoch = generation
    pendingWrite?.cancel()
    requestedVolume = target
    isApplying = true
    lastError = nil
    let clock = clock
    let task = Task { @MainActor [weak self] in
      try await clock.sleep(.milliseconds(100))
      try Task.checkCancellation()
      guard let self, self.generation == epoch else { throw CancellationError() }
      let result = try await self.scripts.run(script: "set volume alert volume \(percent)")
      try Task.checkCancellation()
      guard self.generation == epoch else { throw CancellationError() }
      guard result.status == 0 else {
        throw DeviceBackendError.operationFailed(
          "Unable to change system alert volume (status \(result.status)): \(result.output)")
      }
      let observed = try await self.readPercent()
      try Task.checkCancellation()
      guard self.generation == epoch else { throw CancellationError() }
      self.observedVolume = Float(observed) / 100
      guard observed == percent else {
        throw DeviceBackendError.operationFailed(
          "The system did not confirm the requested alert volume.")
      }
    }
    pendingWrite = task
    do {
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      if generation == epoch {
        pendingWrite = nil
        isApplying = false
      }
    } catch {
      if generation == epoch {
        pendingWrite = nil
        isApplying = false
        if !(error is CancellationError) { lastError = error }
      }
      throw error
    }
  }

  public func stop() {
    generation &+= 1
    pendingWrite?.cancel()
    pendingWrite = nil
    isApplying = false
  }

  isolated deinit { pendingWrite?.cancel() }

  private func readPercent() async throws -> Int {
    let result = try await scripts.run(script: Self.readScript)
    guard result.status == 0 else {
      throw DeviceBackendError.operationFailed(
        "Unable to read system alert volume (status \(result.status)): \(result.output)")
    }
    guard let percent = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
      (0...100).contains(percent)
    else {
      throw DeviceBackendError.operationFailed("The system returned an invalid alert volume.")
    }
    return percent
  }
}
