import AppKit
import AudioToolbox
import Darwin
import FineTuneDomain
import Observation

/// Read-only device discovery. The observation is the single source of its legacy array getters.
@Observable @MainActor
public final class AudioDeviceMonitor: AudioDeviceObservationProviding {
  public private(set) var observation = AudioDeviceObservationSnapshot()
  public var outputDevices: [AudioDevice] { observation.outputDevices }
  public var inputDevices: [AudioDevice] { observation.inputDevices }
  public var lastError: (any Error)? { observation.health.error }
  public var onObservationChanged: (() -> Void)?
  public var onDeviceDisconnected: ((String, String) -> Void)?
  public var onDeviceConnected: ((String, String) -> Void)?
  public var onInputDeviceDisconnected: ((String, String) -> Void)?
  public var onInputDeviceConnected: ((String, String) -> Void)?
  public var onSampleRateChanged: ((String, Double) -> Void)?
  /// Bluetooth can report several nominal rates while a codec/profile transition settles. A
  /// format revision published mid-transition invalidates a healthy aggregate and can leave it
  /// rendering at a rate the device no longer uses.
  static let rateSettlingInterval: Duration = .milliseconds(150)

  private let inventory: any AudioDeviceInventoryReading
  private let subscriptions: AudioObservationSubscriptions
  private let rateClock: DeviceBackendClock
  private var projection = DeviceObservationProjection()
  private var rates: [String: Double] = [:]
  private var pendingRateUIDs: Set<String> = []
  private var rateTasks: [String: Task<Void, Never>] = [:]
  private var running = false
  private var generation: UInt64 = 0

  public convenience init() {
    self.init(
      inventory: CoreAudioObservationInventory(), observer: CoreAudioDevicePropertyObserver())
  }
  init(
    inventory: any AudioDeviceInventoryReading, observer: any AudioDevicePropertyObserving,
    rateClock: DeviceBackendClock = .continuous
  ) {
    self.inventory = inventory
    self.subscriptions = AudioObservationSubscriptions(observer: observer)
    self.rateClock = rateClock
  }

  public func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  public func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  nonisolated public static func isMeaningfulRateChange(oldRate: Double, newRate: Double) -> Bool {
    newRate > 0 && oldRate != newRate
  }

  public func start() {
    guard !running else { return }
    running = true
    generation += 1
    refresh()
  }

  public func stop() {
    running = false
    generation += 1
    subscriptions.cancel()
    cancelRateSettling()
    guard observation.health != .notStarted else { return }
    observation = AudioDeviceObservationSnapshot(
      outputDevices: outputDevices, inputDevices: inputDevices, health: .notStarted,
      revision: observation.revision + 1)
    onObservationChanged?()
  }

  public func refresh() { refresh(settledRateUID: nil) }

  /// `settledRateUID` is the device whose rate survived the settling window; its new format is
  /// published now instead of arming another window.
  private func refresh(settledRateUID: String?) {
    let currentGeneration = generation
    do {
      let raw = try inventory.readDevices()
      let oldRates = rates
      if let settledRateUID { pendingRateUIDs.remove(settledRateUID) }
      var observedRates: [String: Double] = [:]
      for row in raw.devices where !row.outputStreams.isEmpty {
        observedRates[row.device.uid] = row.sampleRate
      }
      // The link can return to its original rate before the window closes. Drop the hold instead
      // of leaving the UID pending forever, which would suppress every later rate transition.
      for (uid, rate) in observedRates where pendingRateUIDs.contains(uid) {
        guard let held = oldRates[uid], !Self.isMeaningfulRateChange(oldRate: held, newRate: rate)
        else { continue }
        pendingRateUIDs.remove(uid)
        rateTasks[uid]?.cancel()
        rateTasks[uid] = nil
      }
      for uid in observedRates.keys {
        guard uid != settledRateUID, let old = oldRates[uid],
          Self.isMeaningfulRateChange(oldRate: old, newRate: observedRates[uid]!)
        else { continue }
        if pendingRateUIDs.insert(uid).inserted {
          scheduleRateSettling(uid: uid, generation: currentGeneration)
        }
      }
      var effective = raw.devices
      for index in effective.indices where pendingRateUIDs.contains(effective[index].device.uid) {
        guard let heldRate = oldRates[effective[index].device.uid] else { continue }
        effective[index].sampleRate = heldRate
        for stream in effective[index].outputStreams.indices {
          effective[index].outputStreams[stream].format.mSampleRate = heldRate
        }
      }
      var nextProjection = projection
      let devices = try nextProjection.project(effective)
      if running {
        try subscriptions.sync(raw.observationTargets) { [weak self] in
          guard let self, self.running, self.generation == currentGeneration else { return }
          self.refresh()
        }
      }
      let oldOutputs = outputDevices
      let oldInputs = inputDevices
      var nextRates: [String: Double] = [:]
      for row in raw.devices where devices.outputs.contains(where: { $0.uid == row.device.uid }) {
        nextRates[row.device.uid] = row.sampleRate
      }
      var storedRates = nextRates
      for uid in pendingRateUIDs { storedRates[uid] = oldRates[uid] }
      projection = nextProjection
      rates = storedRates
      guard
        observation.health != .healthy || !sameDeviceObservation(oldOutputs, devices.outputs)
          || !sameDeviceObservation(oldInputs, devices.inputs)
      else { return }
      observation = AudioDeviceObservationSnapshot(
        outputDevices: devices.outputs, inputDevices: devices.inputs, health: .healthy,
        revision: observation.revision + 1)
      let publishedRevision = observation.revision
      onObservationChanged?()
      guard generation == currentGeneration, observation.revision == publishedRevision else {
        return
      }
      notify(
        oldOutputs, new: devices.outputs, removed: onDeviceDisconnected, added: onDeviceConnected)
      notify(
        oldInputs, new: devices.inputs, removed: onInputDeviceDisconnected,
        added: onInputDeviceConnected)
      for (uid, rate) in nextRates {
        guard !pendingRateUIDs.contains(uid), let old = oldRates[uid],
          Self.isMeaningfulRateChange(oldRate: old, newRate: rate)
        else { continue }
        onSampleRateChanged?(uid, rate)
      }
    } catch { fail(error) }
  }

  private func scheduleRateSettling(uid: String, generation: UInt64) {
    rateTasks[uid]?.cancel()
    rateTasks[uid] = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.rateClock.sleep(Self.rateSettlingInterval)
      } catch { return }
      guard self.generation == generation else { return }
      self.rateTasks[uid] = nil
      self.refresh(settledRateUID: uid)
    }
  }

  private func cancelRateSettling() {
    for task in rateTasks.values { task.cancel() }
    rateTasks.removeAll()
    pendingRateUIDs.removeAll()
  }

  private func fail(_ error: any Error) {
    let health = AudioObservationHealth.failed(error.localizedDescription)
    guard observation.health != health else { return }
    observation = AudioDeviceObservationSnapshot(
      outputDevices: outputDevices, inputDevices: inputDevices, health: health,
      revision: observation.revision + 1)
    onObservationChanged?()
  }

  private func notify(
    _ old: [AudioDevice], new: [AudioDevice], removed: ((String, String) -> Void)?,
    added: ((String, String) -> Void)?
  ) {
    let oldUIDs = Set(old.map(\.uid))
    let newUIDs = Set(new.map(\.uid))
    for row in old where !newUIDs.contains(row.uid) { removed?(row.uid, row.name) }
    for row in new where !oldUIDs.contains(row.uid) { added?(row.uid, row.name) }
  }
}

/// Grouped process observation never constructs taps, asks for TCC or registers in its initializer.
@Observable @MainActor
public final class AudioProcessMonitor: AudioProcessObservationProviding {
  public private(set) var observation = AudioProcessObservationSnapshot()
  public var activeApps: [AudioApp] { observation.activeApps }
  public var lastError: (any Error)? { observation.health.error }
  public var onAppsChanged: (([AudioApp]) -> Void)?
  public var onObservationChanged: (() -> Void)?
  private let inventory: any AudioProcessInventoryReading
  private let metadata: any AudioProcessMetadataReading
  private let subscriptions: AudioObservationSubscriptions
  private let clock: any AudioObservationScheduling
  private let currentPID: () -> pid_t
  private var projection = ProcessObservationProjection()
  private var periodic: DevicePropertyObservation?
  private var running = false
  private var generation: UInt64 = 0

  public convenience init() {
    self.init(
      inventory: CoreAudioObservationInventory(), metadata: SystemAudioProcessMetadata(),
      observer: CoreAudioDevicePropertyObserver(), clock: ContinuousAudioObservationClock(),
      currentPID: { getpid() })
  }

  init(
    inventory: any AudioProcessInventoryReading, metadata: any AudioProcessMetadataReading,
    observer: any AudioDevicePropertyObserving, clock: any AudioObservationScheduling,
    currentPID: @escaping () -> pid_t
  ) {
    self.inventory = inventory
    self.metadata = metadata
    self.clock = clock
    self.currentPID = currentPID
    subscriptions = AudioObservationSubscriptions(observer: observer)
  }

  public func start() {
    guard !running else { return }
    running = true
    generation += 1
    let currentGeneration = generation
    refresh()
    guard running, generation == currentGeneration else { return }
    periodic = clock.schedule(every: .seconds(10)) { [weak self] result in
      guard let self, self.running, self.generation == currentGeneration else { return }
      switch result {
      case .success: self.refresh()
      case .failure(let error): self.fail(error)
      }
    }
  }

  public func stop() {
    running = false
    generation += 1
    periodic?.cancel()
    periodic = nil
    subscriptions.cancel()
    guard observation.health != .notStarted else { return }
    observation = AudioProcessObservationSnapshot(
      activeApps: activeApps, health: .notStarted, revision: observation.revision + 1)
    onObservationChanged?()
  }

  public func refresh() {
    let currentGeneration = generation
    do {
      let raw = try inventory.readProcesses()
      let grouped = try AudioProcessGrouper().group(
        raw, metadata: metadata, currentPID: currentPID())
      var nextProjection = projection
      let apps = nextProjection.project(grouped, previous: activeApps)
      if running {
        var targets: Set<AudioObservationTarget> = [
          .init(object: .system, selector: kAudioHardwarePropertyProcessObjectList)
        ]
        for row in raw {
          targets.insert(.init(object: row.objectID, selector: kAudioProcessPropertyIsRunning))
        }
        try subscriptions.sync(targets) { [weak self] in
          guard let self, self.running, self.generation == currentGeneration else { return }
          self.refresh()
        }
      }
      projection = nextProjection
      guard observation.health != .healthy || !sameProcessObservation(activeApps, apps) else {
        return
      }
      observation = AudioProcessObservationSnapshot(
        activeApps: apps, health: .healthy, revision: observation.revision + 1)
      let publishedRevision = observation.revision
      onObservationChanged?()
      guard generation == currentGeneration, observation.revision == publishedRevision else {
        return
      }
      onAppsChanged?(apps)
    } catch { fail(error) }
  }

  private func fail(_ error: any Error) {
    let health = AudioObservationHealth.failed(error.localizedDescription)
    guard observation.health != health else { return }
    observation = AudioProcessObservationSnapshot(
      activeApps: activeApps, health: health, revision: observation.revision + 1)
    onObservationChanged?()
  }
}
