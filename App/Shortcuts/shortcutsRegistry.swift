import AppKit
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import KeyboardShortcuts

/// Assembles shortcut registration, Control planning, device state and App presentation.
@MainActor
final class ShortcutsRegistry {
  private let settings: SettingsManager
  private let popupController: any MenuBarPopupControlling
  private let resolver: any TargetAppResolving
  private let audioEngine: any AudioEngineDispatching
  private let hud: any PerAppHUDPresenting
  private let keyboard: any ShortcutRegistering
  private var planner = VolumeKeyPlanner()
  private var started = false
  private var repeats: [ShortcutAction: Task<Void, Never>] = [:]

  init(
    settings: SettingsManager, popupController: any MenuBarPopupControlling,
    resolver: any TargetAppResolving, audioEngine: any AudioEngineDispatching,
    hud: any PerAppHUDPresenting, keyboard: any ShortcutRegistering = SystemShortcutRegistration()
  ) {
    self.settings = settings
    self.popupController = popupController
    self.resolver = resolver
    self.audioEngine = audioEngine
    self.hud = hud
    self.keyboard = keyboard
  }

  func name(for action: ShortcutAction) -> KeyboardShortcuts.Name { .init(action.stableID) }

  /// Exposes the same Carbon fields without coupling a consumer to the global preference singleton.
  func shortcut(for action: ShortcutAction) -> KeyboardShortcuts.Shortcut? {
    keyboard.shortcut(for: action.stableID)?.keyboardShortcut
  }

  func start() {
    guard !started else { return }
    started = true
    for action in ShortcutAction.allCases {
      if let saved = settings.appSettings.customShortcuts[action.rawValue] {
        keyboard.setShortcut(saved, for: action.stableID)
      }
      keyboard.register(
        identifier: action.stableID,
        onKeyDown: { [weak self] in
          guard let self, self.started else { return }
          self.dispatch(action)
          self.beginRepeating(action)
        },
        onKeyUp: { [weak self] in self?.endRepeating(action) })
    }
  }

  func stop() {
    guard started else { return }
    started = false
    for action in ShortcutAction.allCases {
      endRepeating(action)
      keyboard.unregister(identifier: action.stableID)
    }
  }

  func dispatch(_ action: ShortcutAction) {
    if action == .togglePopup {
      popupController.toggle()
      return
    }
    guard let app = resolveApp() else { return }
    if action == .targetAppMuteToggle {
      audioEngine.toggleMute(for: app)
      hud.showPerAppMuteHUD(app: app, isMuted: audioEngine.isMuted(for: app))
      return
    }
    let event: MediaKeyEvent =
      action == .targetAppVolumeUp
      ? .volumeUp(isRepeat: false) : .volumeDown(isRepeat: false)
    // App gain uses the software taper, through the very same plan as system media keys.
    guard
      let change = planner.plan(
        event: event, tier: .software, currentGain: audioEngine.currentVolume(for: app),
        currentMute: audioEngine.isMuted(for: app), step: settings.appSettings.volumeHotkeyStep,
        nowNanoseconds: DispatchTime.now().uptimeNanoseconds
      )
    else { return }
    if let muted = change.mute { audioEngine.setMute(for: app, to: muted) }
    if let gain = change.gain { audioEngine.setVolume(for: app, to: gain) }
    hud.showPerAppVolumeHUD(app: app, sliderFraction: change.sliderFraction)
  }

  func recordCallback(for action: ShortcutAction)
    -> @MainActor (KeyboardShortcuts.Shortcut?) -> Void
  {
    { [weak self] shortcut in
      guard let self else { return }
      var saved = self.settings.appSettings
      saved.customShortcuts[action.rawValue] = shortcut.map(ShortcutCodable.from)
      self.settings.updateAppSettings(saved)
    }
  }

  private func resolveApp() -> AudioApp? {
    let candidates = audioEngine.apps.compactMap(\.bundleID).filter {
      audioEngine.isAudibleNow(bundleID: $0)
    }
    guard let bundleID = resolver.resolveTargetBundleID(audibleCandidates: candidates) else {
      hud.showPerAppNotControlledHUD(displayName: nil, bundleID: nil, icon: nil)
      return nil
    }
    if let app = audioEngine.apps.first(where: { $0.bundleID == bundleID }) { return app }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    hud.showPerAppNotControlledHUD(
      displayName: running?.localizedName, bundleID: bundleID, icon: running?.icon)
    return nil
  }

  private func beginRepeating(_ action: ShortcutAction) {
    guard action.supportsRepeat else { return }
    endRepeating(action)
    repeats[action] = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
      while !Task.isCancelled {
        guard let self, self.started else { return }
        self.dispatch(action)
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
      }
    }
  }

  private func endRepeating(_ action: ShortcutAction) {
    repeats[action]?.cancel()
    repeats[action] = nil
  }

  isolated deinit {
    for task in repeats.values { task.cancel() }
    if started {
      for action in ShortcutAction.allCases { keyboard.unregister(identifier: action.stableID) }
    }
  }
}
