import Foundation
import Testing

@testable import FineTune

@Suite("Application lifecycle without live OS services")
@MainActor
struct BootstrapLifecycleTests {
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

  @Test("A failed real disk flush defaults to cancelled quit without stopping audio")
  func failedSaveKeepsServicesRunningUntilExplicitDiscard() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    fixture.settings.setVolume(for: "unit.application", to: 0.25)
    try FileManager.default.createDirectory(
      at: fixture.settingsFile, withIntermediateDirectories: false)
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()

    let first = await coordinator.requestQuit()
    #expect(first == .cancelled)
    #expect(coordinator.lastError != nil)
    #expect(fixture.settings.lastSaveError != nil)
    #expect(coordinator.phase == .running)
    #expect(probe.audioActive && probe.inputActive)
    #expect(fixture.settings.getVolume(for: "unit.application") == 0.25)

    let explicitDiscard = await coordinator.requestQuit(choice: .withoutSaving)
    #expect(explicitDiscard == .terminate)
    #expect(coordinator.phase == .stopped)
    #expect(!probe.audioActive && !probe.inputActive)
    #expect(probe.backgroundFinished)
  }

  @Test("Retry after disk repair saves the latest wish before normal termination")
  func retrySavesCurrentValues() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(
      at: fixture.settingsFile, withIntermediateDirectories: false)
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    fixture.settings.setVolume(for: "unit.application", to: 0.2)
    #expect(await coordinator.requestQuit() == .cancelled)
    fixture.settings.setVolume(for: "unit.application", to: 0.4)
    try fixture.removeSaveObstruction()
    #expect(await coordinator.requestQuit() == .terminate)
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: fixture.settingsFile))
    #expect(saved.appVolumes["unit.application"] == 0.4)
    #expect(coordinator.lastError == nil)
    #expect(!probe.audioActive && !probe.inputActive)
  }
  @Test("A failed shutdown cannot acknowledge successful termination")
  func shutdownFailureIsVisibleAndRetryable() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    await coordinator.start()
    probe.failShutdown = true
    #expect(await coordinator.requestQuit() == .cancelled)
    #expect(coordinator.phase == .failed)
    #expect(coordinator.lastError?.contains("injected shutdown failure") == true)
    #expect(probe.audioActive)
    probe.failShutdown = false
    #expect(await coordinator.requestQuit() == .terminate)
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
