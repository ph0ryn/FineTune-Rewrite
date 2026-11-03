import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation

struct MediaKeyDeviceSnapshot {
  let id: AudioDeviceID
  let tier: VolumeControlTier
  let name: String
  let gain: Float
  let muted: Bool
}

/// App composition translates events into Control plans and routes the effects to its adapters.
/// No device, permission request, or global event source is started by construction.
@MainActor
final class MediaKeyMonitor {
  private let decoder: any MediaKeyEventDecoding
  private let settingsManager: SettingsManager
  private let accessibility: any AccessibilityTrustProviding
  private let hudController: any MediaKeyHUDPresenting
  private let popupVisibility: PopupVisibilityService
  private let mediaKeyStatus: MediaKeyStatus
  private let tapInstaller: any MediaKeyTapInstalling
  private let readDevice: () -> MediaKeyDeviceSnapshot?
  private let writeVolume: (AudioDeviceID, Float) -> Void
  private let writeMute: (AudioDeviceID, Bool) -> Void
  private let now: () -> UInt64
  private var planner = VolumeKeyPlanner()
  private var installed = false
  private var watchdogTask: Task<Void, Never>?

  private(set) var watchdogOpen = false
  var onRunLoopSourceRemoved: (() -> Void)?
  var iconCoordinator: (any MediaKeyIconFlashing)?
  var feedbackPlayer: VolumeFeedbackPlayer?

  init(
    decoder: any MediaKeyEventDecoding, settingsManager: SettingsManager,
    accessibility: any AccessibilityTrustProviding, hudController: any MediaKeyHUDPresenting,
    popupVisibility: PopupVisibilityService, mediaKeyStatus: MediaKeyStatus,
    tapInstaller: any MediaKeyTapInstalling,
    readDevice: @escaping () -> MediaKeyDeviceSnapshot?,
    writeVolume: @escaping (AudioDeviceID, Float) -> Void,
    writeMute: @escaping (AudioDeviceID, Bool) -> Void,
    now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.decoder = decoder
    self.settingsManager = settingsManager
    self.accessibility = accessibility
    self.hudController = hudController
    self.popupVisibility = popupVisibility
    self.mediaKeyStatus = mediaKeyStatus
    self.tapInstaller = tapInstaller
    self.readDevice = readDevice
    self.writeVolume = writeVolume
    self.writeMute = writeMute
    self.now = now
  }

  func start() {
    guard !installed, settingsManager.appSettings.mediaKeyControlEnabled, accessibility.isTrusted
    else { return }
    installed = tapInstaller.install(
      onData: { [weak self] data, shift, option in
        self?.process(data1: data, shiftHeld: shift, optionHeld: option) ?? false
      },
      onDisabled: { [weak self] in self?.handleTapDisabled() })
    mediaKeyStatus.isOffline = !installed
  }

  func reconcile() {
    if settingsManager.appSettings.mediaKeyControlEnabled && accessibility.isTrusted {
      start()
    } else {
      stop()
    }
  }

  func stop() {
    watchdogTask?.cancel()
    watchdogTask = nil
    watchdogOpen = false
    if tapInstaller.stop() { onRunLoopSourceRemoved?() }
    installed = false
  }

  func handleTapDisabled() {
    guard accessibility.isTrusted else {
      stop()
      accessibility.refresh()
      return
    }
    if watchdogOpen {
      watchdogTask?.cancel()
      watchdogTask = nil
      watchdogOpen = false
      mediaKeyStatus.isOffline = true
      return
    }
    watchdogOpen = true
    watchdogTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.watchdogOpen = false
      self?.watchdogTask = nil
    }
    tapInstaller.enable()
  }

  private func process(data1: Int, shiftHeld: Bool, optionHeld: Bool) -> Bool {
    guard installed, settingsManager.appSettings.mediaKeyControlEnabled,
      let event = decoder.decode(data1: data1)
    else { return false }
    hudController.swallowObserved()
    handle(event, shiftHeld: shiftHeld, optionHeld: optionHeld)
    return true
  }

  func handle(_ event: MediaKeyEvent, shiftHeld: Bool = false, optionHeld: Bool = false) {
    guard let device = readDevice(), device.id != kAudioObjectUnknown else { return }
    handleCore(
      event: event, deviceID: device.id, tier: device.tier, deviceName: device.name,
      currentVolume: device.gain, currentMute: device.muted,
      setVolume: writeVolume, setMute: writeMute,
      playFeedback: { [weak self] gain in
        self?.feedbackPlayer?.requestFeedback(
          gain: gain, shiftHeld: shiftHeld, optionHeld: optionHeld)
      })
  }

  func handleCore(
    event: MediaKeyEvent, deviceID: AudioDeviceID, tier: VolumeControlTier,
    deviceName: String, currentVolume: Float, currentMute: Bool,
    setVolume: (AudioDeviceID, Float) -> Void,
    setMute: (AudioDeviceID, Bool) -> Void,
    playFeedback: (Float) -> Void = { _ in }
  ) {
    guard
      let change = planner.plan(
        event: event, tier: tier, currentGain: currentVolume, currentMute: currentMute,
        step: settingsManager.appSettings.volumeHotkeyStep, nowNanoseconds: now()
      )
    else { return }
    if let muted = change.mute { setMute(deviceID, muted) }
    if let gain = change.gain { setVolume(deviceID, gain) }
    if let feedback = change.feedbackGain { playFeedback(feedback) }
    if !popupVisibility.isVisible {
      hudController.show(
        sliderFraction: change.sliderFraction, mute: change.displayedMute, deviceName: deviceName)
    }
    iconCoordinator?.flashDevice()
  }

  isolated deinit {
    watchdogTask?.cancel()
    tapInstaller.stop()
  }
}
