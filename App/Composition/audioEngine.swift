import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Observation

/// App metadata/DTO and media-key facade over the Root's one actual Control owner.
/// Root owns monitor lifetimes and fans out their callback slots into explicit ingestion.
@Observable @MainActor
final class AudioEngine {
  let controller: AudioController
  let settingsManager: SettingsManager
  let deviceVolumeMonitor: any DeviceVolumeProviding
  private let deviceObservations: any AudioDeviceObservationProviding
  private let processObservations: any AudioProcessObservationProviding
  private let readOutputFailure: @MainActor () -> String?

  init(
    controller: AudioController, settingsManager: SettingsManager,
    deviceObservations: any AudioDeviceObservationProviding,
    processObservations: any AudioProcessObservationProviding,
    deviceVolumeMonitor: any DeviceVolumeProviding,
    readOutputFailure: @escaping @MainActor () -> String?
  ) {
    self.controller = controller
    self.settingsManager = settingsManager
    self.deviceObservations = deviceObservations
    self.processObservations = processObservations
    self.deviceVolumeMonitor = deviceVolumeMonitor
    self.readOutputFailure = readOutputFailure
  }

  var apps: [AudioApp] { processObservations.observation.activeApps }
  var volumeState: VolumeState { controller.volumeState }

  func currentVolume(for app: AudioApp) -> Float {
    controller.gain(for: app.persistenceIdentifier)
  }

  func isMuted(for app: AudioApp) -> Bool {
    controller.isMuted(for: app.persistenceIdentifier)
  }

  func toggleMute(for app: AudioApp) {
    controller.perform(.toggleMuted(identifier: app.persistenceIdentifier))
  }

  /// Raw/key volume changes preserve mute. UI slider editing uses the common editGain command.
  func setVolume(for app: AudioApp, to volume: Float) {
    controller.perform(.setGain(identifier: app.persistenceIdentifier, gain: volume))
  }

  func setMute(for app: AudioApp, to muted: Bool) {
    controller.perform(.setMuted(identifier: app.persistenceIdentifier, muted: muted))
  }

  func setDevice(for app: AudioApp, deviceUID: String) {
    controller.perform(
      .setRoute(identifier: app.persistenceIdentifier, mode: .single, uids: [deviceUID]))
  }

  /// The canonical producer already verifies running eligible process objects. No getter performs HAL I/O.
  func isAudibleNow(bundleID: String) -> Bool {
    guard processObservations.observation.health == .healthy else { return false }
    return apps.contains { $0.bundleID == bundleID && !$0.processObjectIDs.isEmpty }
  }

  func ingestObservations() {
    let processes = processObservations.observation
    // Publish peer failures before a healthy process delta can plan against stale output metadata.
    if case .failed(let message) = processes.health {
      controller.observeApplications([], failure: message)
    }
    refreshDeviceLevels()
    if processes.health == .healthy {
      controller.observeApplications(
        processes.activeApps.map { app in
          AudioApplicationDescriptor(
            identifier: app.persistenceIdentifier, processID: app.id,
            processRevision: app.processRevision, displayName: app.name, bundleID: app.bundleID,
            processObjectIDs: app.processObjectIDs)
        })
    }
  }

  func refreshDeviceLevels() {
    if let failure = readOutputFailure() {
      controller.observeOutputs([], defaultUID: nil, failure: failure)
      return
    }
    let snapshot = deviceObservations.observation
    switch snapshot.health {
    case .notStarted: return
    case .failed(let message): controller.observeOutputs([], defaultUID: nil, failure: message)
    case .healthy:
      controller.observeOutputs(
        snapshot.outputDevices.map { device in
          AudioOutputDescriptor(
            uid: device.uid, bindingRevision: device.bindingRevision,
            supportsAutoEQ: device.supportsAutoEQ,
            processingGain: deviceVolumeMonitor.outputProcessingGain(for: device.id),
            volume: deviceVolumeMonitor.volumes[device.id],
            isMuted: deviceVolumeMonitor.muteStates[device.id])
        }, defaultUID: deviceVolumeMonitor.defaultDeviceUID)
    }
  }

  func shutdown() async { await controller.shutdown() }
}
