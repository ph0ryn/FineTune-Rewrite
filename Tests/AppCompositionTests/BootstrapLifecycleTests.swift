import Foundation
import Observation
import Testing

@testable import FineTune

@Suite("Application lifecycle without live OS services")
@MainActor
struct BootstrapLifecycleTests {
  @Test("Cached observation maintenance survives suspension without delivering suspended effects")
  func cachedObservationSurvivesSleep() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    let cache = LifecycleDefaultCache()
    var delivered: [String] = []
    await coordinator.start()
    coordinator.observeWhileStarted(
      read: {
        _ = cache.uid
        _ = cache.failure
      },
      onChange: { delivered.append(cache.uid) })
    await coordinator.handle(.systemWillSleep)
    cache.failure = "Default read unavailable while suspended"
    await drainObservationTasks()
    #expect(delivered.isEmpty)
    await coordinator.handle(.systemDidWake)
    cache.failure = nil
    await drainObservationTasks()
    #expect(delivered == ["A"])
    cache.uid = "B"
    await drainObservationTasks()
    #expect(delivered == ["A", "B"])
    await coordinator.stop()
  }

  @Test("Queued observations cannot re-arm an old session after stop and restart")
  func stoppedObservationCannotDuplicateNewSession() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    let cache = LifecycleDefaultCache()
    var delivered: [String] = []
    await coordinator.start()
    coordinator.observeWhileStarted(
      read: { _ = cache.uid }, onChange: { delivered.append("old:\(cache.uid)") })
    cache.uid = "late"
    await coordinator.stop()
    await coordinator.start()
    coordinator.observeWhileStarted(
      read: { _ = cache.uid }, onChange: { delivered.append("new:\(cache.uid)") })
    cache.uid = "B"
    await drainObservationTasks()
    #expect(delivered == ["new:B"])
    cache.uid = "C"
    await drainObservationTasks()
    #expect(delivered == ["new:B", "new:C"])
    await coordinator.stop()
  }

  private func drainObservationTasks() async {
    // Bounded executor turns, not a real timer, polling loop, or production scheduler.
    for _ in 0..<8 { await Task.yield() }
  }

  @Test("Construction is inert; explicit starts and stops are idempotent")
  func explicitLifecycle() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)

    #expect(coordinator.phase == .idle)
    #expect(!probe.audioActive && !probe.inputActive)
    #expect(probe.startedSessions == 0)
    await coordinator.start()
    await coordinator.start()
    #expect(coordinator.phase == .running)
    #expect(probe.audioActive && probe.inputActive)
    #expect(probe.startedSessions == 1)
    await coordinator.stop()
    await coordinator.stop()
    #expect(coordinator.phase == .stopped)
    #expect(!probe.audioActive && !probe.inputActive)
    #expect(probe.backgroundFinished)
  }

  @Test("Session input recovery never stops audio; sleep preserves capture wish")
  func sessionAndSystemSleepAreDifferent() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    var preferences = fixture.settings.appSettings
    preferences.explicitUserCaptureEnabled = true
    fixture.settings.updateAppSettings(preferences)
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()

    await coordinator.handle(.sessionResigned)
    #expect(probe.audioActive && !probe.inputActive)
    await coordinator.handle(.sessionBecameActive)
    #expect(probe.audioActive && probe.inputActive)
    await coordinator.handle(.systemWillSleep)
    #expect(coordinator.phase == .suspended)
    #expect(!probe.audioActive && !probe.inputActive)
    #expect(fixture.settings.appSettings.explicitUserCaptureEnabled)
    await coordinator.handle(.systemDidWake)
    #expect(coordinator.phase == .running)
    #expect(probe.audioActive && probe.inputActive)
    await coordinator.stop()
    #expect(fixture.settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Retained callbacks cannot mutate persisted wishes after stop or restart")
  func staleCallbackCannotSubmitCommands() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    let oldCallback = coordinator.callbackWhileRunning {
      fixture.settings.setVolume(for: "unit.application", to: 0.9)
    }
    oldCallback()
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.9)
    fixture.settings.setVolume(for: "unit.application", to: 0.3)
    await coordinator.stop()
    oldCallback()
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.3)
    await coordinator.start()
    oldCallback()
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.3)
    coordinator.callbackWhileRunning {
      fixture.settings.setVolume(for: "unit.application", to: 0.6)
    }()
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.6)
    await coordinator.stop()
  }

  @Test("Partial startup is cleaned, its error stays visible, and retry can run")
  func partialStartupRecovery() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    probe.failStartup = true
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    #expect(coordinator.phase == .failed)
    #expect(coordinator.lastError?.contains("injected startup failure") == true)
    #expect(!probe.audioActive && !probe.inputActive)
    #expect(probe.backgroundFinished)

    probe.failStartup = false
    await coordinator.start()
    #expect(coordinator.phase == .running)
    #expect(coordinator.lastError == nil)
    #expect(probe.audioActive && probe.inputActive)
    await coordinator.stop()
  }

  @Test("Termination stops input and saves pending settings without awaiting audio shutdown")
  func terminationSavesOnTheCurrentTurn() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    let retainedCallback = coordinator.callbackWhileRunning {
      fixture.settings.setVolume(for: "unit.application", to: 0.9)
    }
    fixture.settings.setVolume(for: "unit.application", to: 0.25)

    coordinator.prepareForTermination()
    #expect(coordinator.phase == .stopping)
    #expect(!probe.inputActive)
    #expect(probe.audioActive && !probe.backgroundFinished)
    #expect(fixture.settings.lastSaveError == nil)
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: fixture.settingsFile))
    #expect(saved.appVolumes["unit.application"] == 0.25)
    retainedCallback()
    await coordinator.handle(.sessionBecameActive)
    #expect(!probe.inputActive)
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.25)
    // The test process stays alive: clean up its injected async service explicitly.
    await coordinator.stop()
  }

  @Test("Like the original, a failed flush stays observable but does not defer termination")
  func failedTerminationSaveDoesNotWaitForAUserDecision() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    fixture.settings.setVolume(for: "unit.application", to: 0.25)
    try FileManager.default.createDirectory(
      at: fixture.settingsFile, withIntermediateDirectories: false)
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()

    coordinator.prepareForTermination()
    #expect(fixture.settings.lastSaveError != nil)
    #expect(coordinator.phase == .stopping)
    #expect(probe.audioActive && !probe.inputActive)
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.25)
    await coordinator.stop()
  }

  @Test("A repaired termination flush saves current values and clears the disk error")
  func terminationFlushSavesCurrentValues() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(
      at: fixture.settingsFile, withIntermediateDirectories: false)
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    fixture.settings.setVolume(for: "unit.application", to: 0.2)
    coordinator.prepareForTermination()
    #expect(fixture.settings.lastSaveError != nil)
    fixture.settings.setVolume(for: "unit.application", to: 0.4)
    try fixture.removeSaveObstruction()
    coordinator.prepareForTermination()
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: fixture.settingsFile))
    #expect(saved.appVolumes["unit.application"] == 0.4)
    #expect(fixture.settings.lastSaveError == nil)
    #expect(probe.audioActive && !probe.inputActive)
    await coordinator.stop()
  }

  @Test("Cooperative shutdown failures remain visible and retryable outside app termination")
  func shutdownFailureIsVisibleAndRetryable() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    probe.failShutdown = true
    await coordinator.stop()
    #expect(coordinator.phase == .failed)
    #expect(coordinator.lastError?.contains("injected shutdown failure") == true)
    #expect(probe.audioActive)
    probe.failShutdown = false
    await coordinator.stop()
    #expect(coordinator.phase == .stopped)
    #expect(!probe.audioActive && probe.backgroundFinished)
  }

  @Test("Failed wake recovery keeps the wish and clears its error after successful retry")
  func wakeFailureRecovery() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    await coordinator.handle(.systemWillSleep)
    probe.failResume = true
    await coordinator.handle(.systemDidWake)
    #expect(coordinator.phase == .suspended)
    #expect(coordinator.lastError?.contains("injected resume failure") == true)
    probe.failResume = false
    await coordinator.handle(.systemDidWake)
    #expect(coordinator.phase == .running)
    #expect(coordinator.lastError == nil)
    #expect(probe.audioActive && probe.inputActive)
    await coordinator.stop()
  }
}

@MainActor
@Observable
private final class LifecycleDefaultCache {
  var uid = "A"
  var failure: String?
}

@MainActor
private final class LifecycleServiceProbe {
  var audioActive = false
  var inputActive = false
  var backgroundFinished = true
  var startedSessions = 0
  var failStartup = false
  var failShutdown = false
  var failResume = false
  private var backgroundTask: Task<Void, Never>?

  var ports: LifecyclePorts {
    LifecyclePorts(
      start: { try await self.start() },
      shutdown: { try await self.shutdown() },
      suspendAudio: { self.audioActive = false },
      resumeAudio: {
        if self.failResume { throw LifecycleProbeFailure(operation: "resume") }
        self.audioActive = true
      },
      suspendInput: { self.inputActive = false },
      resumeInput: { self.inputActive = true }
    )
  }

  private func start() async throws {
    startedSessions += 1
    audioActive = true
    inputActive = true
    backgroundFinished = false
    let started = AsyncStream<Void>.makeStream()
    let pending = AsyncStream<Void>.makeStream()
    backgroundTask = Task { @MainActor in
      started.continuation.yield(())
      for await _ in pending.stream {}
      self.backgroundFinished = true
    }
    var readiness = started.stream.makeAsyncIterator()
    _ = await readiness.next()
    if failStartup { throw LifecycleProbeFailure(operation: "startup") }
  }

  private func shutdown() async throws {
    if failShutdown { throw LifecycleProbeFailure(operation: "shutdown") }
    backgroundTask?.cancel()
    await backgroundTask?.value
    backgroundTask = nil
    audioActive = false
    inputActive = false
  }
}

private struct LifecycleProbeFailure: Error, CustomStringConvertible {
  let operation: String
  var description: String { "injected \(operation) failure" }
}

@MainActor
private struct LifecycleFixture {
  let directory: URL
  let settings: SettingsManager
  var settingsFile: URL { directory.appendingPathComponent("settings.json") }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneRewrite-Lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    settings = SettingsManager(directory: directory, launchAtLoginService: LifecycleLoginSpy())
  }

  func removeSaveObstruction() throws {
    precondition(settingsFile.deletingLastPathComponent() == directory)
    try FileManager.default.removeItem(at: settingsFile)
  }

  func cleanUp() {
    precondition(directory.lastPathComponent.hasPrefix("FineTuneRewrite-Lifecycle-"))
    try! FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class LifecycleLoginSpy: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
