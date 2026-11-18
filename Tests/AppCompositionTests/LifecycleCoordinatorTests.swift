import AppTestSupport
import FineTunePlatform
import Foundation
import Observation
import Testing

@testable import FineTune

@Suite(
  "App composition: LifecycleCoordinator phase and generation control", .timeLimit(.minutes(1)))
@MainActor
struct LifecycleCoordinatorTests {
  @Test("Cached observation maintenance survives suspension without delivering suspended effects")
  func cachedObservationSurvivesSleep() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    let cache = LifecycleDefaultCache()
    let (events, eventSink) = AsyncStream<LifecycleObservationEvent>.makeStream()
    var delivered: [String] = []
    try await withAsyncTestCleanup(
      operation: {
        await coordinator.start()
        coordinator.observeWhileStarted(
          read: {
            eventSink.yield(.read(uid: cache.uid, failure: cache.failure))
          },
          onChange: {
            delivered.append(cache.uid)
            eventSink.yield(.delivery(cache.uid))
          })
        let initial = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "initial cached observation")
        #expect(initial == .read(uid: "A", failure: nil))
        await coordinator.handle(.systemWillSleep)
        cache.failure = "Default read unavailable while suspended"
        let suspended = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "suspended cached observation")
        #expect(
          suspended == .read(uid: "A", failure: "Default read unavailable while suspended"))
        #expect(delivered.isEmpty)
        await coordinator.handle(.systemDidWake)
        cache.failure = nil
        let resumedRead = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "resumed cached observation")
        #expect(resumedRead == .read(uid: "A", failure: nil))
        let resumedDelivery = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "resumed observation delivery")
        #expect(resumedDelivery == .delivery("A"))
        #expect(delivered == ["A"])
        cache.uid = "B"
        let changedRead = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "changed cached observation")
        #expect(changedRead == .read(uid: "B", failure: nil))
        let changedDelivery = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "changed observation delivery")
        #expect(changedDelivery == .delivery("B"))
        #expect(delivered == ["A", "B"])
      },
      cleanup: {
        eventSink.finish()
        await coordinator.stop()
      })
  }

  @Test("Queued observations cannot re-arm an old session after stop and restart")
  func stoppedObservationCannotDuplicateNewSession() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanUp() }
    let probe = LifecycleServiceProbe()
    let coordinator = LifecycleCoordinator(settings: fixture.settings, ports: probe.ports)
    let cache = LifecycleDefaultCache()
    let (events, eventSink) = AsyncStream<LifecycleObservationEvent>.makeStream()
    var delivered: [String] = []
    try await withAsyncTestCleanup(
      operation: {
        await coordinator.start()
        coordinator.observeWhileStarted(
          read: { eventSink.yield(.read(uid: cache.uid, failure: nil)) },
          onChange: {
            delivered.append("old:\(cache.uid)")
            eventSink.yield(.delivery("old:\(cache.uid)"))
          })
        let initial = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "initial lifecycle observation")
        #expect(initial == .read(uid: "A", failure: nil))
        cache.uid = "late"
        await coordinator.stop()
        await coordinator.start()
        coordinator.observeWhileStarted(
          read: { eventSink.yield(.read(uid: cache.uid, failure: nil)) },
          onChange: {
            delivered.append("new:\(cache.uid)")
            eventSink.yield(.delivery("new:\(cache.uid)"))
          })
        let restarted = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "restarted lifecycle observation")
        #expect(restarted == .read(uid: "late", failure: nil))
        cache.uid = "B"
        let changedB = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "B lifecycle observation")
        #expect(changedB == .read(uid: "B", failure: nil))
        let deliveryB = try await waitForTestStreamElement(
          of: events, finishing: eventSink, waitedFor: "B lifecycle delivery")
        #expect(deliveryB == .delivery("new:B"))
        #expect(delivered == ["new:B"])
      },
      cleanup: {
        eventSink.finish()
        await coordinator.stop()
      })
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

  @Test(
    "Termination stops input and flushes pending settings synchronously without awaiting audio shutdown"
  )
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

private enum LifecycleObservationEvent: Equatable, Sendable {
  case read(uid: String, failure: String?)
  case delivery(String)
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
      resumeInput: { self.inputActive = true })
  }

  private func start() async throws {
    startedSessions += 1
    audioActive = true
    inputActive = true
    backgroundFinished = false
    let started = AsyncStream<Void>.makeStream()
    let pending = AsyncStream<Void>.makeStream()
    backgroundTask = Task { @MainActor [weak self] in
      started.continuation.yield(())
      for await _ in pending.stream {}
      self?.backgroundFinished = true
    }
    do {
      _ = try await waitForTestStreamElement(
        of: started.stream, finishing: started.continuation,
        waitedFor: "lifecycle service startup")
      started.continuation.finish()
      if failStartup { throw LifecycleProbeFailure(operation: "startup") }
    } catch {
      started.continuation.finish()
      pending.continuation.finish()
      backgroundTask?.cancel()
      await backgroundTask?.value
      backgroundTask = nil
      audioActive = false
      inputActive = false
      throw error
    }
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

  func cleanUp() {
    precondition(directory.lastPathComponent.hasPrefix("FineTuneRewrite-Lifecycle-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class LifecycleLoginSpy: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
