import FineTuneDomain
import FineTunePlatform
import Foundation
import Observation

/// What the App composition resolved for the device that currently receives system sounds.
/// The policy needs the tier and the observed mute; neither is inferred here.
struct SystemAlertSilencingTarget: Equatable, Sendable {
  let deviceUID: String
  let tier: VolumeControlTier
  let isMuted: Bool
}

/// Mirrors a software mute of the system-sounds output on the OS alert volume.
///
/// A hardware or DDC mute already silences the device, and the tap never reaches system alerts,
/// so only a software-tier mute leaves alert sounds audible through a muted device. While such a
/// mute is active the previous alert volume is saved and the OS alert volume is set to zero; the
/// previous value returns when the mute ends, including after an interrupted process.
@MainActor @Observable
final class SystemAlertSilencing {
  private let alertVolume: AlertVolumeBackend
  private let settings: SettingsManager

  private(set) var isSilenced = false
  private(set) var lastError: String?

  @ObservationIgnored private var target: SystemAlertSilencingTarget?
  @ObservationIgnored private var savedVolume: Float?
  @ObservationIgnored private var tail: Task<Void, Never>?
  @ObservationIgnored private var isStarting = false

  init(alertVolume: AlertVolumeBackend, settings: SettingsManager) {
    self.alertVolume = alertVolume
    self.settings = settings
  }

  isolated deinit { tail?.cancel() }

  static func shouldSilence(_ target: SystemAlertSilencingTarget?) -> Bool {
    guard let target else { return false }
    return target.tier == .software && target.isMuted
  }

  /// Queues the startup refresh/restore behind any earlier work, then applies the saved intent.
  func start() {
    guard !isStarting else { return }
    isStarting = true
    append { [weak self] in
      guard let self else { return }
      if self.settings.alertVolumeBeforeMuteSilencing == nil {
        await self.alertVolume.refresh()
      }
      self.isStarting = false
      await self.applyCurrentTarget()
    }
  }

  /// Only a changed readback enters the queue; repeated projections stay passive.
  func update(target newTarget: SystemAlertSilencingTarget?) {
    guard newTarget != target else { return }
    target = newTarget
    guard !isStarting else { return }
    append { [weak self] in await self?.applyCurrentTarget() }
  }

  /// Joins the serial queue. Lifecycle boundaries and component tests wait on this.
  func awaitTransitions() async {
    await tail?.value
  }

  func stop() async {
    tail?.cancel()
    await awaitTransitions()
    isStarting = false
    target = nil
    if isSilenced {
      _ = await restore()
    } else if let pending = settings.alertVolumeBeforeMuteSilencing {
      _ = await finishInterruptedRestore(pending)
    }
  }

  /// The AppKit will-terminate turn cannot await; one blocking write keeps the OS volume intact.
  /// The persisted restore value stays: a write racing the exit is finished on the next launch.
  func prepareForTermination() {
    tail?.cancel()
    guard isSilenced || settings.alertVolumeBeforeMuteSilencing != nil else { return }
    guard let restore = savedVolume ?? settings.alertVolumeBeforeMuteSilencing else { return }
    if alertVolume.restoreForTermination(restore) {
      isSilenced = false
      savedVolume = nil
    }
  }

  private func append(_ operation: @escaping @MainActor () async -> Void) {
    let previous = tail
    tail = Task {
      await previous?.value
      guard !Task.isCancelled else { return }
      await operation()
    }
  }

  private func applyCurrentTarget() async {
    if !isSilenced, let pending = settings.alertVolumeBeforeMuteSilencing {
      guard await finishInterruptedRestore(pending) else { return }
    }
    while Self.shouldSilence(target) != isSilenced {
      if Self.shouldSilence(target) {
        guard await silence() else { return }
      } else {
        guard await restore() else { return }
      }
    }
  }

  private func silence() async -> Bool {
    guard !isSilenced else { return true }
    guard let current = alertVolume.observedVolume else {
      lastError = "The system alert volume is unavailable; alerts were not silenced."
      return false
    }
    savedVolume = current
    settings.setAlertVolumeBeforeMuteSilencing(current)
    // Persist the restore value before the OS leaves its previous state.
    settings.flushSync()
    isSilenced = true
    do {
      try await alertVolume.setVolume(0)
      lastError = nil
      return true
    } catch is CancellationError {
      // A stopping or terminating turn keeps the restore value; its owner restores eventually.
      return false
    } catch {
      isSilenced = false
      savedVolume = nil
      settings.setAlertVolumeBeforeMuteSilencing(nil)
      settings.flushSync()
      lastError = "Couldn’t silence system alerts: \(error.localizedDescription)"
      return false
    }
  }

  private func restore() async -> Bool {
    guard isSilenced, let restore = savedVolume else { return true }
    do {
      try await alertVolume.setVolume(restore)
      isSilenced = false
      savedVolume = nil
      settings.setAlertVolumeBeforeMuteSilencing(nil)
      settings.flushSync()
      lastError = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      // The OS may still be at zero; keep the intent for the next attempt and the next launch.
      settings.setAlertVolumeBeforeMuteSilencing(restore)
      settings.flushSync()
      lastError = "Couldn’t restore the system alert volume: \(error.localizedDescription)"
      return false
    }
  }

  /// Only a restore persisted by an interrupted process reaches this path.
  private func finishInterruptedRestore(_ volume: Float) async -> Bool {
    do {
      try await alertVolume.setVolume(volume)
      settings.setAlertVolumeBeforeMuteSilencing(nil)
      settings.flushSync()
      lastError = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      lastError = "Couldn’t restore the system alert volume: \(error.localizedDescription)"
      return false
    }
  }
}
