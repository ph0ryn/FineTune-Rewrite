import AppKit
import AudioToolbox
import Testing

@testable import FineTunePlatform

@Suite("Audio process owner grouping")
@MainActor
struct AudioProcessGroupingTests {
  @Test("Fixture revision stays zero; persistence preserves exact spelling")
  func processRevisionContract() {
    let fixture = AudioApp(
      id: 10, processObjectIDs: [20], name: "Display Name", icon: NSImage(), bundleID: "Com.Player")
    #expect(fixture.processRevision == 0)
    #expect(fixture.persistenceIdentifier == "Com.Player")
    let observed = AudioApp(
      id: 10, processObjectIDs: [20, 21], name: "Display Name", icon: NSImage(),
      bundleID: "Com.Player", processRevision: 7)
    #expect(observed.processRevision == 7)
    #expect(
      AudioApp(id: 11, processObjectIDs: [], name: "Exact Case", icon: NSImage(), bundleID: nil)
        .persistenceIdentifier == "name:Exact Case")
  }

  @Test("Unobserved resolution and constructor IO are rejected independently")
  func coldAndUnobserved() {
    let source = ProcessObservationFixture()
    #expect(source.inventory.reads == 0)
    #expect(source.metadata.reads == 0)
    #expect(source.observer.registrations.isEmpty)
    #expect(source.clock.schedules == 0)
    #expect(source.monitor.observation.health == .notStarted)
    #expect(throws: AudioAppObservationResolutionError.unavailable("Com.Player")) {
      try source.monitor.resolveApp(identifier: "Com.Player", processRevision: 7)
    }
  }

  @Test(
    "AppKit's documented no-PID application does not reject an unrelated HAL process frame",
    arguments: [false, true])
  func noPIDWorkspaceEntryDoesNotRejectFrame(running: Bool) throws {
    let source = ProcessObservationFixture()
    // Minimized read-only OS sample: a .app/accessory workspace entry had PID -1 while
    // HAL object 99/PID 884 was valid and inactive. `true` is controlled test activity,
    // not evidence of live playback. Display metadata is anonymized.
    source.metadata.apps = [
      observationApp(pid: -1, name: "Unbound App", bundle: "Com.Unbound"),
      observationApp(pid: 884),
    ]
    source.inventory.processes = [observationProcess(99, pid: 884, running: running)]

    source.monitor.refresh()

    #expect(source.monitor.observation.health == .healthy)
    #expect(source.monitor.lastError == nil)
    #expect(source.monitor.activeApps.count == (running ? 1 : 0))
    if running {
      let app = try #require(source.monitor.activeApps.only)
      #expect(app.id == 884)
      #expect(app.processObjectIDs == [99])
      #expect(app.processRevision > 0)
      #expect(
        try source.monitor.resolveApp(
          identifier: "Com.Player", processRevision: app.processRevision
        ).processObjectIDs == [99])
    }
  }

  @Test("Malformed and duplicate process-bearing application metadata still fail closed")
  func invalidApplicationMetadataStillFailsClosed() throws {
    let source = ProcessObservationFixture()
    source.monitor.refresh()
    let good = try #require(source.monitor.activeApps.only)
    let malformed = [
      [observationApp(), observationApp(pid: 0)],
      [observationApp(), observationApp(pid: -2)],
      [observationApp(), observationApp(name: "Conflicting App", bundle: "Com.Other")],
    ]
    for apps in malformed {
      source.metadata.apps = apps
      source.monitor.refresh()
      #expect(
        source.monitor.observation.health
          == .failed("Application metadata has an invalid or duplicate process identity."))
      #expect(source.monitor.activeApps.only?.processObjectIDs == good.processObjectIDs)
      #expect(source.monitor.activeApps.only?.processRevision == good.processRevision)
      #expect(throws: AudioAppObservationResolutionError.unavailable(good.persistenceIdentifier)) {
        try source.monitor.resolveApp(
          identifier: good.persistenceIdentifier, processRevision: good.processRevision)
      }
    }
  }

  @Test("AppKit's no-PID sentinel never legitimizes an invalid HAL process binding")
  func invalidHALBindingStillFailsClosed() throws {
    let source = ProcessObservationFixture()
    source.monitor.refresh()
    let good = try #require(source.monitor.activeApps.only)
    for process in [
      observationProcess(11, pid: -1), observationProcess(0, pid: 101),
      observationProcess(10, pid: 101),
    ] {
      source.inventory.processes = [observationProcess(10, pid: 100), process]
      source.monitor.refresh()
      #expect(source.monitor.lastError != nil)
      #expect(source.monitor.activeApps.only?.processObjectIDs == good.processObjectIDs)
      #expect(source.monitor.activeApps.only?.processRevision == good.processRevision)
      #expect(throws: AudioAppObservationResolutionError.unavailable(good.persistenceIdentifier)) {
        try source.monitor.resolveApp(
          identifier: good.persistenceIdentifier, processRevision: good.processRevision)
      }
    }
  }

  @Test("Chrome/Electron parent fallback and WebKit responsibility share owner metadata")
  func ownerProjection() throws {
    for (name, responsible) in [("Chrome", false), ("Electron", false), ("WebKit", true)] {
      let source = ProcessObservationFixture()
      source.metadata.apps = [observationApp(pid: 100, name: name, bundle: "Com.Owner")]
      source.inventory.processes = [
        observationProcess(42, pid: 200), observationProcess(41, pid: 201),
        observationProcess(42, pid: 200),
      ]
      if responsible {
        source.metadata.responsibility = [200: 100, 201: 100]
      } else {
        source.metadata.parents = [200: 100, 201: 100]
      }
      source.monitor.refresh()
      let app = try #require(source.monitor.activeApps.only)
      #expect(app.id == 100)
      #expect(app.name == name)
      #expect(app.bundleID == "Com.Owner")
      #expect(app.processObjectIDs == [41, 42])
      #expect(app.isHelperBacked)
      #expect(app.processRevision > 0)
    }
  }

  @Test("Self, own helpers, original daemons and nonrunning objects never enter grouped apps")
  func exclusions() {
    let source = ProcessObservationFixture()
    source.metadata.apps = [
      observationApp(pid: 100), observationApp(pid: 999, name: "Self", bundle: "Com.Self"),
    ]
    source.metadata.responsibility = [998: 999]
    source.inventory.processes = [
      observationProcess(1, pid: 999), observationProcess(2, pid: 998),
      observationProcess(3, pid: 666, bundle: "com.apple.siri.agent"),
      observationProcess(4, pid: 777, running: false), observationProcess(5, pid: 100),
    ]
    source.monitor.refresh()
    #expect(source.monitor.activeApps.map(\.id) == [100])
    #expect(source.monitor.activeApps.first?.processObjectIDs == [5])
  }

  @Test("Cycle and invalid responsibility answers fall back without inventing a main owner")
  func unresolvedAndInvalidResponsibility() throws {
    let source = ProcessObservationFixture()
    source.inventory.processes = [observationProcess(41, pid: 200, bundle: "Com.Unresolved")]
    source.metadata.names = [200: "Unresolved Helper"]
    source.metadata.parents = [200: 201, 201: 200]
    source.metadata.responsibility = [200: -1]
    source.monitor.refresh()
    let unresolved = try #require(source.monitor.activeApps.only)
    #expect(unresolved.id == 200)
    #expect(unresolved.bundleID == "Com.Unresolved")
    #expect(!unresolved.isHelperBacked)
    #expect(source.metadata.parentReads <= 3)
    source.metadata.apps = [observationApp(pid: 100)]
    source.metadata.parents = [200: 100]
    for invalid in [pid_t(0), -1, 200] {
      source.metadata.responsibility = [200: invalid]
      source.monitor.refresh()
      #expect(source.monitor.activeApps.only?.id == 100)
    }
  }

  @Test("Only identity, normalized membership or main binding changes advance process revision")
  func revisions() throws {
    let source = ProcessObservationFixture()
    source.monitor.refresh()
    let first = try #require(source.monitor.activeApps.only)
    let firstObservation = source.monitor.observation.revision
    source.metadata.apps = [observationApp(pid: 100, name: "Display Rename", icon: NSImage())]
    source.inventory.processes = [
      observationProcess(10, pid: 100), observationProcess(10, pid: 100),
    ]
    source.monitor.refresh()
    #expect(source.monitor.activeApps.only?.processRevision == first.processRevision)
    #expect(source.monitor.observation.revision > firstObservation)
    source.inventory.processes.append(observationProcess(11, pid: 100))
    source.monitor.refresh()
    let members = try #require(source.monitor.activeApps.only)
    #expect(members.processRevision != first.processRevision)
    source.metadata.apps = [observationApp(pid: 100, name: "First", bundle: nil)]
    source.monitor.refresh()
    let fallback = try #require(source.monitor.activeApps.only)
    source.metadata.apps = [observationApp(pid: 100, name: "Second", bundle: nil)]
    source.monitor.refresh()
    #expect(source.monitor.activeApps.only?.persistenceIdentifier == "name:Second")
    #expect(source.monitor.activeApps.only?.processRevision != fallback.processRevision)
  }

  @Test("Read and metadata failure retain last good; valid empty is a different observation")
  func failureAndEmpty() {
    let source = ProcessObservationFixture()
    source.monitor.refresh()
    let previous = source.monitor.activeApps
    source.inventory.failure = ObservationTestError.reader
    source.monitor.refresh()
    #expect(source.monitor.activeApps.map(\.id) == previous.map(\.id))
    #expect(source.monitor.lastError != nil)
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Read failure was called healthy")
    }
    source.inventory.failure = nil
    source.metadata.failure = ObservationTestError.metadata
    source.monitor.refresh()
    #expect(source.monitor.activeApps.map(\.id) == previous.map(\.id))
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Metadata failure was called healthy")
    }
    source.metadata.failure = nil
    source.inventory.processes = []
    source.monitor.refresh()
    #expect(source.monitor.activeApps.isEmpty)
    #expect(source.monitor.observation.health == .healthy)
  }

  @Test("Exact current resolution rejects spelling, stale binding and failed observations")
  func exactResolution() throws {
    let source = ProcessObservationFixture()
    source.monitor.refresh()
    let app = try #require(source.monitor.activeApps.only)
    #expect(
      try source.monitor.resolveApp(identifier: "Com.Player", processRevision: app.processRevision)
        .id == 100)
    #expect(throws: AudioAppObservationResolutionError.unavailable("com.player")) {
      try source.monitor.resolveApp(identifier: "com.player", processRevision: app.processRevision)
    }
    source.inventory.processes.append(observationProcess(11, pid: 100))
    source.monitor.refresh()
    #expect(throws: AudioAppObservationResolutionError.bindingChanged("Com.Player")) {
      try source.monitor.resolveApp(identifier: "Com.Player", processRevision: app.processRevision)
    }
    source.inventory.failure = ObservationTestError.reader
    source.monitor.refresh()
    #expect(throws: AudioAppObservationResolutionError.unavailable("Com.Player")) {
      try source.monitor.resolveApp(
        identifier: "Com.Player", processRevision: source.monitor.activeApps[0].processRevision)
    }
  }

  @Test("Unchanged unresolved metadata does not fabricate a new observation on each safety poll")
  func unchangedFallbackObservation() {
    let source = ProcessObservationFixture()
    source.metadata.apps = []
    source.metadata.names = [100: "CLI Player"]
    source.monitor.refresh()
    let revision = source.monitor.observation.revision
    let binding = source.monitor.activeApps.first?.processRevision
    source.monitor.refresh()
    #expect(source.monitor.observation.revision == revision)
    #expect(source.monitor.activeApps.first?.processRevision == binding)
  }

  @Test("A new main PID is a new process binding even with the same saved identity and raw member")
  func mainBindingChange() throws {
    let source = ProcessObservationFixture()
    source.inventory.processes = [observationProcess(10, pid: 200)]
    source.metadata.parents = [200: 100]
    source.monitor.refresh()
    let old = try #require(source.monitor.activeApps.only)
    source.metadata.apps = [observationApp(pid: 101)]
    source.metadata.parents = [200: 101]
    source.monitor.refresh()
    let new = try #require(source.monitor.activeApps.only)
    #expect(new.persistenceIdentifier == old.persistenceIdentifier)
    #expect(new.id == 101)
    #expect(new.processObjectIDs == old.processObjectIDs)
    #expect(new.processRevision != old.processRevision)
  }

  @Test(
    "Public self-parent fallback and daemon executable names are excluded without private lookup")
  func publicSelfAndDaemonName() {
    let source = ProcessObservationFixture()
    source.metadata.apps.append(observationApp(pid: 999, name: "Self", bundle: "Com.Self"))
    source.metadata.parents = [200: 999]
    source.metadata.names = [300: "COREAUDIOD"]
    source.inventory.processes = [
      observationProcess(10, pid: 100), observationProcess(20, pid: 200),
      observationProcess(30, pid: 300),
    ]
    source.monitor.refresh()
    #expect(source.monitor.activeApps.map(\.id) == [100])
  }

  @Test("A per-process running event republishes valid disappearance; clock failure stays failed")
  func runningAndClockFailure() throws {
    let source = ProcessObservationFixture()
    source.monitor.start()
    let index = try #require(
      source.observer.registrations.firstIndex { $0.selector == kAudioProcessPropertyIsRunning })
    source.inventory.processes = [observationProcess(10, pid: 100, running: false)]
    source.observer.callbacks[index]()
    #expect(source.monitor.activeApps.isEmpty)
    #expect(source.monitor.observation.health == .healthy)
    source.clock.tick?(.failure(ObservationTestError.clock))
    if case .failed = source.monitor.observation.health {
    } else {
      Issue.record("Clock failure was hidden")
    }
    source.monitor.stop()
  }

  @Test("Deinitialization owns listener and timer cancellation without a self-retaining callback")
  func deinitializationCancels() {
    let reader = ObservationTestProcessReader()
    let metadata = ObservationTestMetadata()
    let observer = ObservationTestObserver()
    let clock = ObservationTestClock()
    var monitor: AudioProcessMonitor? = AudioProcessMonitor(
      inventory: reader, metadata: metadata, observer: observer, clock: clock, currentPID: { 999 })
    weak let lifetime = monitor
    monitor?.start()
    monitor = nil
    #expect(lifetime == nil)
    #expect(observer.cancelled == observer.registrations.count)
    #expect(clock.cancelled == 1)
  }

  @Test("Published snapshots precede callbacks; running listeners, timer and late stop are owned")
  func publicationAndLifetime() {
    let source = ProcessObservationFixture()
    var published = [UInt64]()
    source.monitor.onObservationChanged = { published.append(source.monitor.observation.revision) }
    source.monitor.onAppsChanged = { apps in
      #expect(source.monitor.observation.activeApps.map(\.id) == apps.map(\.id))
    }
    source.monitor.start()
    #expect(published == [1])
    #expect(source.clock.schedules == 1)
    #expect(
      source.observer.registrations.contains { $0.selector == kAudioProcessPropertyIsRunning })
    source.clock.fire()
    #expect(source.inventory.reads == 2)
    let callbacks = source.observer.callbacks
    let lateTick = source.clock.tick
    source.monitor.stop()
    let reads = source.inventory.reads
    let count = published.count
    for callback in callbacks { callback() }
    lateTick?(.success(()))
    source.clock.fire()
    #expect(source.inventory.reads == reads)
    #expect(published.count == count)
    #expect(source.observer.cancelled == source.observer.registrations.count)
    #expect(source.clock.cancelled == 1)
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}

enum ObservationTestError: Error { case reader, metadata, registration, clock }

@MainActor
func observationApp(
  pid: pid_t = 100, name: String = "Player", bundle: String? = "Com.Player",
  icon: NSImage = NSImage()
) -> ProcessApplicationMetadata {
  ProcessApplicationMetadata(
    pid: pid, name: name, bundleID: bundle, icon: icon, isApplication: true)
}

func observationProcess(
  _ object: AudioObjectID, pid: pid_t, bundle: String? = nil, running: Bool = true
) -> AudioProcessRecord {
  AudioProcessRecord(objectID: object, pid: pid, bundleID: bundle, isRunning: running)
}

@MainActor
final class ObservationTestProcessReader: AudioProcessInventoryReading {
  var processes = [observationProcess(10, pid: 100)]
  var failure: (any Error)?
  var reads = 0
  func readProcesses() throws -> [AudioProcessRecord] {
    reads += 1
    if let failure { throw failure }
    return processes
  }
}

@MainActor
final class ObservationTestMetadata: AudioProcessMetadataReading {
  var apps = [observationApp()]
  var parents: [pid_t: pid_t] = [:]
  var responsibility: [pid_t: pid_t] = [:]
  var names: [pid_t: String] = [:]
  var failure: (any Error)?
  var reads = 0
  var parentReads = 0
  func applications() throws -> [ProcessApplicationMetadata] {
    reads += 1
    if let failure { throw failure }
    return apps
  }
  func processName(for pid: pid_t) throws -> String? { names[pid] }
  func parentPID(of pid: pid_t) throws -> pid_t? {
    parentReads += 1
    return parents[pid]
  }
  func responsiblePID(for pid: pid_t) -> pid_t? { responsibility[pid] }
}

@MainActor
final class ObservationTestObserver: AudioDevicePropertyObserving {
  struct Registration {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
  }
  var registrations: [Registration] = []
  var callbacks: [@MainActor @Sendable () -> Void] = []
  var cancelled = 0
  var failure: (any Error)?
  var failureAfter: Int?
  func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    if let failure { throw failure }
    if let failureAfter, registrations.count >= failureAfter {
      throw ObservationTestError.registration
    }
    registrations.append(Registration(object: object, selector: selector, scope: scope))
    callbacks.append(onChange)
    return DevicePropertyObservation { self.cancelled += 1 }
  }
}

@MainActor
final class ObservationTestClock: AudioObservationScheduling {
  var schedules = 0
  var cancelled = 0
  var tick: (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  func schedule(
    every interval: Duration, tick: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) -> DevicePropertyObservation {
    schedules += 1
    self.tick = tick
    return DevicePropertyObservation {
      self.cancelled += 1
      self.tick = nil
    }
  }
  func fire() { tick?(.success(())) }
}

@MainActor
final class ProcessObservationFixture {
  let inventory = ObservationTestProcessReader()
  let metadata = ObservationTestMetadata()
  let observer = ObservationTestObserver()
  let clock = ObservationTestClock()
  let monitor: AudioProcessMonitor
  init() {
    monitor = AudioProcessMonitor(
      inventory: inventory, metadata: metadata, observer: observer, clock: clock,
      currentPID: { 999 })
  }
}
