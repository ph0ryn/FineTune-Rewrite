import FineTunePlatform
import Observation

/// One lifecycle for the production Root. It does not create OS services, infer
/// capture authorization, or own copies of their settings and background tasks.
@MainActor
@Observable
final class LifecycleCoordinator {
  private let settings: SettingsManager
  private let ports: LifecyclePorts
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0

  private(set) var phase: LifecyclePhase = .idle
  private(set) var lastError: String?

  init(settings: SettingsManager, ports: LifecyclePorts) {
    self.settings = settings
    self.ports = ports
  }

  func start() async {
    if let startupTask {
      await startupTask.value
      return
    }
    guard phase == .idle || phase == .stopped || phase == .failed else { return }
    generation += 1
    let current = generation
    phase = .starting
    lastError = nil
    let work = Task { @MainActor in
      do {
        try await self.ports.start()
        guard self.generation == current, !Task.isCancelled else {
          return
        }
        self.phase = .running
      } catch {
        let startError = String(describing: error)
        var cleanupError: String?
        do {
          try await self.ports.shutdown()
        } catch {
          cleanupError = String(describing: error)
        }
        guard self.generation == current else { return }
        var message = "Couldn’t start audio controls. \(startError)"
        if let cleanupError { message += " Cleanup also failed: \(cleanupError)" }
        self.lastError = message
        self.phase = .failed
      }
    }
    startupTask = work
    await work.value
    if generation == current { startupTask = nil }
  }

  func stop() async {
    guard phase != .stopped else { return }
    generation += 1
    phase = .stopping
    startupTask?.cancel()
    await startupTask?.value
    startupTask = nil
    do {
      try await ports.shutdown()
      phase = .stopped
    } catch {
      lastError = "Couldn’t stop audio controls. \(error)"
      phase = .failed
    }
  }

  /// Only application-owned callbacks use this guard. Service-owned observers
  /// retain their own cancellation/generation contracts rather than a second registry.
  func callbackWhileRunning(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let current = generation
    return { [weak self] in
      guard let self, self.phase == .running, self.generation == current else { return }
      action()
    }
  }

  /// Application-owned cached observations share this coordinator's lifetime.
  func observeWhileStarted(
    read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void
  ) {
    let current = generation
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.generation == current,
          self.phase == .starting || self.phase == .running || self.phase == .suspended
        else { return }
        self.observeWhileStarted(read: read, onChange: onChange)
        if self.phase == .running { onChange() }
      }
    }
  }

  func handle(_ event: LifecycleEvent) async {
    guard phase == .running || phase == .suspended else { return }
    let current = generation
    do {
      switch event {
      case .sessionResigned:
        ports.suspendInput()
      case .sessionBecameActive:
        if phase == .running { ports.resumeInput() }
      case .systemWillSleep:
        guard phase == .running else { return }
        ports.suspendInput()
        try await ports.suspendAudio()
        guard generation == current else { return }
        phase = .suspended
      case .systemDidWake:
        if phase == .suspended { try await ports.resumeAudio() }
        guard generation == current else { return }
        ports.resumeInput()
        phase = .running
        lastError = nil
      }
    } catch {
      guard generation == current else { return }
      lastError = "Couldn’t update audio controls after a system change. \(error)"
    }
  }

  /// Match the original will-terminate hook: stop input and flush on this turn.
  /// Process exit, not an async shutdown/retirement acknowledgement, ends audio ownership.
  func prepareForTermination() {
    generation += 1
    phase = .stopping
    startupTask?.cancel()
    ports.suspendInput()
    settings.flushSync()
  }
}
