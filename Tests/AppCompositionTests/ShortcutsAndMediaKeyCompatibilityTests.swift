import AppKit
import AudioToolbox
import CoreGraphics
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import KeyboardShortcuts
import Testing

@testable import FineTune

// MARK: - Self-Contained Composition Doubles

private final class CompatLaunchAtLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
private final class CompatAccessibilityTrust: AccessibilityTrustProviding {
  var isTrusted: Bool
  var refreshCallCount = 0

  init(isTrusted: Bool = true) {
    self.isTrusted = isTrusted
  }

  func refresh() {
    refreshCallCount += 1
  }
}

private final class CompatStubDecoder: MediaKeyEventDecoding, @unchecked Sendable {
  var nextEvent: MediaKeyEvent?
  func decode(data1: Int) -> MediaKeyEvent? { nextEvent }
}

@MainActor
private final class CompatMediaKeyTapInstaller: MediaKeyTapInstalling {
  var installSucceeds: Bool
  var installed = false
  var events: [String] = []
  var onDataHandler: (@MainActor (Int, Bool, Bool) -> Bool)?
  var onDisabledHandler: (@MainActor () -> Void)?

  init(installSucceeds: Bool = false) {
    self.installSucceeds = installSucceeds
  }

  func install(
    onData: @escaping @MainActor (Int, Bool, Bool) -> Bool,
    onDisabled: @escaping @MainActor () -> Void
  ) -> Bool {
    events.append("install")
    guard installSucceeds else { return false }
    installed = true
    onDataHandler = onData
    onDisabledHandler = onDisabled
    return true
  }

  func enable() { events.append("enable") }

  @discardableResult
  func stop() -> Bool {
    events.append("stop")
    let wasInstalled = installed
    installed = false
    return wasInstalled
  }
}

@MainActor
private final class CompatMediaKeyHUD: MediaKeyHUDPresenting {
  var showCallCount = 0
  var lastFraction: Double?
  var lastMute: Bool?
  var lastDeviceName: String?
  var swallowed = 0

  func show(sliderFraction: Double, mute: Bool, deviceName: String) {
    showCallCount += 1
    lastFraction = sliderFraction
    lastMute = mute
    lastDeviceName = deviceName
  }

  func swallowObserved() { swallowed += 1 }
}

@MainActor
private final class CompatIconFlash: MediaKeyIconFlashing {
  var flashes = 0
  func flashDevice() { flashes += 1 }
}

@MainActor
private final class CompatPopupController: MenuBarPopupControlling {
  var toggleCount = 0
  func toggle() { toggleCount += 1 }
}

@MainActor
private final class CompatTargetResolver: TargetAppResolving {
  var resolvedBundleID: String?
  var lastCandidates: [String] = []
  func resolveTargetBundleID(audibleCandidates: [String]) -> String? {
    lastCandidates = audibleCandidates
    return resolvedBundleID
  }
}

@MainActor
private final class CompatAudioEngineSpy: AudioEngineDispatching {
  var apps: [AudioApp] = []
  var volumes: [Int32: Float] = [:]
  var mutes: [Int32: Bool] = [:]
  var audibleBundleIDs: Set<String> = []
  var setVolumeCalls: [(Int32, Float)] = []
  var setMuteCalls: [(Int32, Bool)] = []
  var toggleMuteCalls: [Int32] = []

  func setVolume(for app: AudioApp, to volume: Float) {
    volumes[app.id] = volume
    setVolumeCalls.append((app.id, volume))
  }

  func setMute(for app: AudioApp, to muted: Bool) {
    mutes[app.id] = muted
    setMuteCalls.append((app.id, muted))
  }

  func toggleMute(for app: AudioApp) {
    let next = !(mutes[app.id] ?? false)
    mutes[app.id] = next
    toggleMuteCalls.append(app.id)
  }

  func currentVolume(for app: AudioApp) -> Float { volumes[app.id] ?? 1.0 }
  func isMuted(for app: AudioApp) -> Bool { mutes[app.id] ?? false }
  func isAudibleNow(bundleID: String) -> Bool { audibleBundleIDs.contains(bundleID) }
}

@MainActor
private final class CompatPerAppHUD: PerAppHUDPresenting {
  var volumeHUDCalls: [(AudioApp, Double)] = []
  var muteHUDCalls: [(AudioApp, Bool)] = []
  var notControlledCalls: [(String?, String?, NSImage?)] = []

  func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) {
    volumeHUDCalls.append((app, sliderFraction))
  }

  func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
    muteHUDCalls.append((app, isMuted))
  }

  func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
    notControlledCalls.append((displayName, bundleID, icon))
  }
}

@MainActor
private final class CompatShortcutRegistrar: ShortcutRegistering {
  var shortcuts: [String: ShortcutCodable] = [:]
  var downHandlers: [String: [@MainActor () -> Void]] = [:]
  var upHandlers: [String: [@MainActor () -> Void]] = [:]
  var unregisterCalls: [String] = []

  func shortcut(for identifier: String) -> ShortcutCodable? { shortcuts[identifier] }
  func setShortcut(_ shortcut: ShortcutCodable?, for identifier: String) {
    shortcuts[identifier] = shortcut
  }

  func register(
    identifier: String,
    onKeyDown: @escaping @MainActor () -> Void,
    onKeyUp: @escaping @MainActor () -> Void
  ) {
    downHandlers[identifier, default: []].append(onKeyDown)
    upHandlers[identifier, default: []].append(onKeyUp)
  }

  func unregister(identifier: String) {
    unregisterCalls.append(identifier)
    downHandlers.removeValue(forKey: identifier)
    upHandlers.removeValue(forKey: identifier)
  }
}

@MainActor
private final class CompatDeviceObs: AudioDeviceObservationProviding {
  var observation = AudioDeviceObservationSnapshot(
    outputDevices: [], inputDevices: [], health: .healthy)
  var onObservationChanged: (() -> Void)?
  var outputDevices: [AudioDevice] { observation.outputDevices }
  var inputDevices: [AudioDevice] { observation.inputDevices }
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  func start() {}
  func stop() {}
}

@MainActor
private final class CompatProcessObs: AudioProcessObservationProviding {
  var observation = AudioProcessObservationSnapshot(activeApps: [], health: .healthy)
  var onObservationChanged: (() -> Void)?
  var activeApps: [AudioApp] { observation.activeApps }
  var onAppsChanged: (([AudioApp]) -> Void)?
  func resolveApp(identifier: String, processRevision: UInt64) throws -> AudioApp {
    throw AudioAppObservationResolutionError.unavailable("unused")
  }
  func start() {}
  func stop() {}
}

@MainActor
private final class CompatDeviceVolume: DeviceVolumeProviding {
  var defaultDeviceID: AudioDeviceID = 0
  var defaultDeviceUID: String?
  var defaultInputDeviceUID: String?
  var volumes: [AudioDeviceID: Float] = [:]
  var muteStates: [AudioDeviceID: Bool] = [:]
  var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
  var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
  var onDefaultDeviceChanged: ((String) -> Void)?
  var onDefaultInputDeviceChanged: ((String) -> Void)?
  func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool { true }
  func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { true }
  func setVolume(for deviceID: AudioDeviceID, to volume: Float) {}
  func setMute(for deviceID: AudioDeviceID, to muted: Bool) {}
  func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
  func outputProcessingGain(for deviceID: AudioDeviceID) -> Float { 1 }
  func refreshOutputDeviceStates() {}
  func applyTierOverrideChange(for deviceID: AudioDeviceID) {}
  func start() {}
  func stop() {}
  func refreshAfterDDCProbe() {}
}

@MainActor
private func makeCompatSettingsManager(mediaKeyEnabled: Bool = true) -> SettingsManager {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let sm = SettingsManager(directory: dir, launchAtLoginService: CompatLaunchAtLoginService())
  var app = sm.appSettings
  app.mediaKeyControlEnabled = mediaKeyEnabled
  sm.updateAppSettings(app)
  return sm
}

private func makeCompatAudioApp(
  id: pid_t = 1001, bundleID: String = "com.example.music", processObjects: [AudioObjectID] = [1]
) -> AudioApp {
  AudioApp(
    id: id,
    processObjectIDs: processObjects,
    name: "MusicApp",
    icon: NSImage(size: NSSize(width: 16, height: 16)),
    bundleID: bundleID
  )
}

// MARK: - MediaKeyMonitor Handler Tests

@Suite("Upstream MediaKeyMonitor Handler Compatibility")
@MainActor
struct UpstreamMediaKeyMonitorHandlerCompatibilityTests {

  private func makeMonitor(
    installSucceeds: Bool = true,
    popupVisible: Bool = false,
    now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) -> (
    MediaKeyMonitor, CompatMediaKeyHUD, PopupVisibilityService, SettingsManager,
    CompatMediaKeyTapInstaller, CompatStubDecoder
  ) {
    let settings = makeCompatSettingsManager(mediaKeyEnabled: true)
    let popup = PopupVisibilityService()
    popup.isVisible = popupVisible
    let hud = CompatMediaKeyHUD()
    let tap = CompatMediaKeyTapInstaller(installSucceeds: installSucceeds)
    let decoder = CompatStubDecoder()
    let monitor = MediaKeyMonitor(
      decoder: decoder,
      settingsManager: settings,
      accessibility: CompatAccessibilityTrust(isTrusted: true),
      hudController: hud,
      popupVisibility: popup,
      mediaKeyStatus: MediaKeyStatus(),
      tapInstaller: tap,
      readDevice: { nil },
      writeVolume: { _, _ in true },
      writeMute: { _, _ in true },
      now: now
    )
    return (monitor, hud, popup, settings, tap, decoder)
  }

  @Test("Software tier steps in slider domain (x^2 taper) and diverges from hardware linear steps")
  func softwareVsHardwareTaperSteps() {
    let (monitor, _, _, _, _, _) = makeMonitor()
    var swVol: Float = 0.5
    var hwVol: Float = 0.5

    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
      deviceName: "SW", currentVolume: swVol, currentMute: false,
      setVolume: { _, v in
        swVol = v
        return true
      }, setMute: { _, _ in true })
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 2, tier: .hardware,
      deviceName: "HW", currentVolume: hwVol, currentMute: false,
      setVolume: { _, v in
        hwVol = v
        return true
      }, setMute: { _, _ in true })

    #expect(abs(hwVol - 0.5625) < 1e-5)
    let expectedSW = Float(pow(sqrt(0.5) + 1.0 / 16.0, 2))
    #expect(abs(swVol - expectedSW) < 1e-5)
    #expect(swVol != hwVol)

    // Lower clamp & upper clamp
    var zero: Float = 0
    monitor.handleCore(
      event: .volumeDown(isRepeat: false), deviceID: 1, tier: .software,
      deviceName: "SW", currentVolume: zero, currentMute: false,
      setVolume: { _, v in
        zero = v
        return true
      }, setMute: { _, _ in true })
    #expect(zero == 0)

    var nearMax: Float = 0.95
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: nearMax, currentMute: false,
      setVolume: { _, v in
        nearMax = v
        return true
      }, setMute: { _, _ in true })
    #expect(nearMax == 1.0)
  }

  @Test("Volume repeats accumulate cleanly and DDC 80ms coalescing gates repeats")
  func repeatsAndDDCCoalescing() {
    var clockNs: UInt64 = 1_000_000_000
    let (monitor, _, _, _, _, _) = makeMonitor(now: { clockNs })

    // Hardware repeats are NOT coalesced
    var hwVol: Float = 0.5
    for _ in 0..<4 {
      monitor.handleCore(
        event: .volumeUp(isRepeat: true), deviceID: 1, tier: .hardware,
        deviceName: "HW", currentVolume: hwVol, currentMute: false,
        setVolume: { _, v in
          hwVol = v
          return true
        }, setMute: { _, _ in true })
    }
    #expect(abs(hwVol - 0.75) < 1e-5)

    // DDC repeats within 80ms coalesce; at exactly 80ms a write is admitted; non-repeat always writes
    var ddcWrites = 0
    for step in 0..<4 {
      if step == 3 {
        clockNs += 80_000_000
      } else {
        clockNs += 10_000_000
      }
      monitor.handleCore(
        event: .volumeUp(isRepeat: true), deviceID: 2, tier: .ddc,
        deviceName: "DDC", currentVolume: 0.5, currentMute: false,
        setVolume: { _, _ in
          ddcWrites += 1
          return true
        }, setMute: { _, _ in true })
    }
    #expect(ddcWrites == 2)

    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 2, tier: .ddc,
      deviceName: "DDC", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in
        ddcWrites += 1
        return true
      }, setMute: { _, _ in true })
    #expect(ddcWrites == 3)
  }

  @Test(
    "Mute transitions on volumeUp, volumeDown to zero, volumeDown while muted at zero, and muteToggle"
  )
  func muteTransitionMatrix() {
    let (monitor, _, _, _, _, _) = makeMonitor()

    // volumeUp while muted auto-unmutes
    var muteWrites: [Bool] = []
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: true,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    #expect(muteWrites == [false])

    // volumeUp while unmuted does not write mute
    muteWrites.removeAll()
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    #expect(muteWrites.isEmpty)

    // volumeDown reaching 0 while unmuted auto-mutes
    monitor.handleCore(
      event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 1.0 / 16.0, currentMute: false,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    #expect(muteWrites == [true])

    // volumeDown already at 0 while muted does not touch mute
    muteWrites.removeAll()
    monitor.handleCore(
      event: .volumeDown(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0, currentMute: true,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    #expect(muteWrites.isEmpty)

    // muteToggle toggles both ways
    monitor.handleCore(
      event: .muteToggle, deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    monitor.handleCore(
      event: .muteToggle, deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: true,
      setVolume: { _, _ in true },
      setMute: { _, m in
        muteWrites.append(m)
        return true
      })
    #expect(muteWrites == [true, false])
  }

  @Test(
    "HUD suppression when popup visible, repeat HUD behavior, rejected write suppression, and feedback hook"
  )
  func hudRejectionAndFeedback() {
    let (_, hudVisible, _, _, _, _) = makeMonitor(popupVisible: true)
    // Re-create monitor cleanly with popupVisible=true
    let popup = PopupVisibilityService()
    popup.isVisible = true
    let monitorPopupOpen = MediaKeyMonitor(
      decoder: CompatStubDecoder(),
      settingsManager: makeCompatSettingsManager(),
      accessibility: CompatAccessibilityTrust(isTrusted: true),
      hudController: hudVisible,
      popupVisibility: popup,
      mediaKeyStatus: MediaKeyStatus(),
      tapInstaller: CompatMediaKeyTapInstaller(installSucceeds: true),
      readDevice: { nil },
      writeVolume: { _, _ in true },
      writeMute: { _, _ in true }
    )
    monitorPopupOpen.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in true }, setMute: { _, _ in true })
    #expect(hudVisible.showCallCount == 0)

    // Rejected write suppresses HUD, icon flash, and feedback
    let (monitor, hud, _, _, _, _) = makeMonitor(popupVisible: false)
    let icon = CompatIconFlash()
    monitor.iconCoordinator = icon
    for rejectMute in [true, false] {
      var feedbackCount = 0
      monitor.handleCore(
        event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
        deviceName: "HW", currentVolume: 0.5, currentMute: true,
        setVolume: { _, _ in false },
        setMute: { _, _ in !rejectMute },
        playFeedback: { _ in feedbackCount += 1 })
      #expect(feedbackCount == 0)
      #expect(hud.showCallCount == 0)
      #expect(icon.flashes == 0)
    }

    // Software vs hardware feedback gain + silent muteToggle
    var swWritten: Float?
    var swFeedback: Float?
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .software,
      deviceName: "SW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, v in
        swWritten = v
        return true
      },
      setMute: { _, _ in true },
      playFeedback: { swFeedback = $0 })
    #expect(swFeedback != nil && swFeedback == swWritten)

    var hwFeedback: Float?
    monitor.handleCore(
      event: .volumeUp(isRepeat: false), deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in true }, setMute: { _, _ in true },
      playFeedback: { hwFeedback = $0 })
    #expect(hwFeedback == 1.0)

    var muteFeedbackCalls = 0
    monitor.handleCore(
      event: .muteToggle, deviceID: 1, tier: .hardware,
      deviceName: "HW", currentVolume: 0.5, currentMute: false,
      setVolume: { _, _ in true }, setMute: { _, _ in true },
      playFeedback: { _ in muteFeedbackCalls += 1 })
    #expect(muteFeedbackCalls == 0)
  }

  @Test(
    "Installed HID callback applies control plan, stays inert after stop, and marks failed install offline"
  )
  func installedTapCallbacksAndOfflineStatus() throws {
    let settings = makeCompatSettingsManager()
    let status = MediaKeyStatus()
    let hud = CompatMediaKeyHUD()
    let tap = CompatMediaKeyTapInstaller(installSucceeds: true)
    let decoder = CompatStubDecoder()
    decoder.nextEvent = .volumeUp(isRepeat: false)

    var currentGain: Float = 0.5
    var writtenGain: Float?
    let monitor = MediaKeyMonitor(
      decoder: decoder,
      settingsManager: settings,
      accessibility: CompatAccessibilityTrust(isTrusted: true),
      hudController: hud,
      popupVisibility: PopupVisibilityService(),
      mediaKeyStatus: status,
      tapInstaller: tap,
      readDevice: {
        MediaKeyDeviceSnapshot(
          id: 7, tier: .hardware, name: "Desk", gain: currentGain, muted: false)
      },
      writeVolume: { _, v in
        writtenGain = v
        currentGain = v
        return true
      },
      writeMute: { _, _ in true }
    )

    monitor.start()
    let onData = try #require(tap.onDataHandler)
    let swallowed = onData(0, true, false)
    #expect(swallowed)
    #expect(abs((writtenGain ?? 0) - 0.5625) < 1e-5)
    #expect(hud.showCallCount == 1)

    monitor.stop()
    let afterStop = onData(0, true, false)
    #expect(!afterStop)
    #expect(hud.showCallCount == 1)

    // Failed install marks status offline
    let failStatus = MediaKeyStatus()
    let failMonitor = MediaKeyMonitor(
      decoder: decoder,
      settingsManager: settings,
      accessibility: CompatAccessibilityTrust(isTrusted: true),
      hudController: hud,
      popupVisibility: PopupVisibilityService(),
      mediaKeyStatus: failStatus,
      tapInstaller: CompatMediaKeyTapInstaller(installSucceeds: false),
      readDevice: { nil },
      writeVolume: { _, _ in true },
      writeMute: { _, _ in true }
    )
    failMonitor.start()
    #expect(failStatus.isOffline)
  }
}

// MARK: - MediaKeyMonitor Lifecycle & Watchdog Tests

@Suite("Upstream MediaKeyMonitor Lifecycle & Watchdog Compatibility")
@MainActor
struct UpstreamMediaKeyLifecycleCompatibilityTests {

  private func makeMonitor(
    enabled: Bool = true,
    installSucceeds: Bool = false,
    trusted: Bool = true
  ) -> (
    MediaKeyMonitor, MediaKeyStatus, CompatAccessibilityTrust, CompatMediaKeyTapInstaller,
    CompatMediaKeyHUD
  ) {
    let status = MediaKeyStatus()
    let trust = CompatAccessibilityTrust(isTrusted: trusted)
    let tap = CompatMediaKeyTapInstaller(installSucceeds: installSucceeds)
    let hud = CompatMediaKeyHUD()
    let monitor = MediaKeyMonitor(
      decoder: CompatStubDecoder(),
      settingsManager: makeCompatSettingsManager(mediaKeyEnabled: enabled),
      accessibility: trust,
      hudController: hud,
      popupVisibility: PopupVisibilityService(),
      mediaKeyStatus: status,
      tapInstaller: tap,
      readDevice: { nil },
      writeVolume: { _, _ in true },
      writeMute: { _, _ in true }
    )
    return (monitor, status, trust, tap, hud)
  }

  @Test(
    "Lifecycle: disabled start skips tap, double start/stop are idempotent, stop clears watchdog")
  func lifecycleGuards() {
    let (disabledMonitor, disabledStatus, _, disabledTap, _) = makeMonitor(enabled: false)
    disabledMonitor.start()
    #expect(!disabledStatus.isOffline)
    #expect(disabledTap.events.isEmpty)

    let (monitor, _, _, tap, hud) = makeMonitor(enabled: true, installSucceeds: true)
    var hookFired = false
    monitor.onRunLoopSourceRemoved = { hookFired = true }
    monitor.start()
    monitor.start()
    #expect(tap.events == ["install"])

    monitor.handleTapDisabled()
    #expect(monitor.watchdogOpen)
    monitor.stop()
    monitor.stop()
    #expect(!monitor.watchdogOpen)
    #expect(hookFired)
    #expect(tap.events == ["install", "enable", "stop", "stop"])

    // 10 hardware repeats drive 10 HUD show calls
    var vol: Float = 0
    for _ in 0..<10 {
      monitor.handleCore(
        event: .volumeUp(isRepeat: true), deviceID: 1, tier: .hardware,
        deviceName: "Test", currentVolume: vol, currentMute: false,
        setVolume: { _, v in
          vol = v
          return true
        }, setMute: { _, _ in true })
    }
    #expect(hud.showCallCount == 10)
  }

  @Test(
    "Tap-disabled watchdog handles single disable, double disable offline, and AX revocation idempotently"
  )
  func tapDisabledWatchdog() {
    let (monitor, status, _, _, _) = makeMonitor(trusted: true)
    #expect(!status.isOffline)
    monitor.handleTapDisabled()
    #expect(!status.isOffline)
    #expect(monitor.watchdogOpen)

    monitor.handleTapDisabled()
    #expect(status.isOffline)
    #expect(!monitor.watchdogOpen)

    let (revokedMonitor, revokedStatus, trust, _, _) = makeMonitor(trusted: false)
    revokedMonitor.handleTapDisabled()
    revokedMonitor.handleTapDisabled()
    #expect(!revokedStatus.isOffline)
    #expect(!revokedMonitor.watchdogOpen)
    #expect(trust.refreshCallCount == 2)
  }
}

// MARK: - ShortcutsRegistry, TargetAppResolver & AudioEngine.isAudibleNow

@Suite("Upstream ShortcutsRegistry & TargetAppResolver Compatibility")
@MainActor
struct UpstreamShortcutsAndTargetResolverCompatibilityTests {

  private func makeRegistryFixture() -> (
    ShortcutsRegistry, CompatPopupController, CompatTargetResolver, CompatAudioEngineSpy,
    CompatPerAppHUD, CompatShortcutRegistrar, SettingsManager
  ) {
    let settings = makeCompatSettingsManager()
    let popup = CompatPopupController()
    let resolver = CompatTargetResolver()
    let engine = CompatAudioEngineSpy()
    let hud = CompatPerAppHUD()
    let registrar = CompatShortcutRegistrar()
    let registry = ShortcutsRegistry(
      settings: settings,
      popupController: popup,
      resolver: resolver,
      audioEngine: engine,
      hud: hud,
      keyboard: registrar
    )
    return (registry, popup, resolver, engine, hud, registrar, settings)
  }

  @Test(
    "ShortcutsRegistry dispatch handles togglePopup, volume steps, auto-mute/unmute, and unknown target HUD"
  )
  func dispatchBehavior() {
    let (registry, popup, resolver, engine, hud, _, _) = makeRegistryFixture()
    let app = makeCompatAudioApp(id: 50, bundleID: "com.test.app")
    engine.apps = [app]
    engine.audibleBundleIDs = ["com.test.app"]
    resolver.resolvedBundleID = "com.test.app"

    registry.dispatch(.togglePopup)
    #expect(popup.toggleCount == 1)

    engine.volumes[app.id] = 0.5
    engine.mutes[app.id] = true
    registry.dispatch(.targetAppVolumeUp)
    let expectedUp = Float(pow(sqrt(0.5) + 1.0 / 16.0, 2))
    #expect(abs((engine.volumes[app.id] ?? 0) - expectedUp) < 1e-5)
    #expect(engine.setMuteCalls.last?.1 == false)
    #expect(hud.volumeHUDCalls.count == 1)

    // Already unmuted does not issue redundant setMute
    engine.setMuteCalls.removeAll()
    registry.dispatch(.targetAppVolumeUp)
    #expect(engine.setMuteCalls.isEmpty)

    // VolumeDown hitting zero on software taper auto-mutes (1/16 slider fraction -> (1/16)^2 gain)
    engine.volumes[app.id] = Float(pow(1.0 / 16.0, 2))
    registry.dispatch(.targetAppVolumeDown)
    #expect(engine.volumes[app.id] == 0)
    #expect(engine.setMuteCalls.last?.1 == true)

    // VolumeDown above zero while muted unmutes
    engine.volumes[app.id] = 0.5
    engine.mutes[app.id] = true
    registry.dispatch(.targetAppVolumeDown)
    #expect(engine.setMuteCalls.last?.1 == false)

    // Mute toggle
    registry.dispatch(.targetAppMuteToggle)
    #expect(hud.muteHUDCalls.count == 1)

    // Missing resolver or missing AudioApp hits fallback HUD
    resolver.resolvedBundleID = nil
    registry.dispatch(.targetAppVolumeUp)
    #expect(hud.notControlledCalls.count == 1)

    resolver.resolvedBundleID = "com.unknown.app"
    registry.dispatch(.targetAppVolumeUp)
    #expect(hud.notControlledCalls.count == 2)
  }

  @Test(
    "ShortcutsRegistry registration loads stored shortcuts, updates AppSettings, and neutralizes after stop"
  )
  func registrationLifecycleAndCallbacks() throws {
    let (registry, _, resolver, engine, hud, registrar, settings) = makeRegistryFixture()
    let shortcut = ShortcutCodable(keyCode: 12, modifiers: 256)
    var appSettings = settings.appSettings
    appSettings.customShortcuts[ShortcutAction.togglePopup.rawValue] = shortcut
    settings.updateAppSettings(appSettings)

    #expect(ShortcutAction.targetAppVolumeUp.supportsRepeat)
    #expect(ShortcutAction.targetAppVolumeDown.supportsRepeat)
    #expect(!ShortcutAction.targetAppMuteToggle.supportsRepeat)
    #expect(!ShortcutAction.togglePopup.supportsRepeat)
    #expect(registry.name(for: .togglePopup).rawValue == ShortcutAction.togglePopup.stableID)

    registry.start()
    registry.start()
    #expect(registrar.shortcuts[ShortcutAction.togglePopup.stableID] == shortcut)
    #expect(registrar.downHandlers[ShortcutAction.targetAppVolumeUp.stableID]?.count == 1)

    // recordCallback writes & clears AppSettings
    let callback = registry.recordCallback(for: .targetAppMuteToggle)
    let recorded = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
    callback(recorded)
    #expect(
      settings.appSettings.customShortcuts[ShortcutAction.targetAppMuteToggle.rawValue] != nil)
    callback(nil)
    #expect(
      settings.appSettings.customShortcuts[ShortcutAction.targetAppMuteToggle.rawValue] == nil)

    // Retained callback reaches engine then becomes inert after stop
    let app = makeCompatAudioApp(id: 51, bundleID: "com.test.cb")
    engine.apps = [app]
    engine.audibleBundleIDs = ["com.test.cb"]
    resolver.resolvedBundleID = "com.test.cb"
    engine.volumes[app.id] = 0.5

    let volUpCallback = try #require(
      registrar.downHandlers[ShortcutAction.targetAppVolumeUp.stableID]?.first)
    volUpCallback()
    #expect(hud.volumeHUDCalls.count == 1)

    registry.stop()
    #expect(registrar.unregisterCalls.count == ShortcutAction.allCases.count)
    volUpCallback()
    #expect(hud.volumeHUDCalls.count == 1)
  }

  @Test(
    "TargetAppResolver skips own bundleID, prefers frontmost external app, and returns nil when empty"
  )
  func targetAppResolver() {
    final class FrontmostBox: @unchecked Sendable {
      var bundleID: String? = "com.finetune.self"
    }
    let box = FrontmostBox()
    let resolver = TargetAppResolver(
      ownBundleID: "com.finetune.self",
      frontmostBundleIDProvider: { box.bundleID }
    )
    #expect(
      resolver.resolveTargetBundleID(audibleCandidates: ["com.spotify.client"])
        == "com.spotify.client")

    box.bundleID = "com.apple.Safari"
    #expect(
      resolver.resolveTargetBundleID(audibleCandidates: ["com.spotify.client", "com.apple.Safari"])
        == "com.apple.Safari")

    box.bundleID = "com.nonexistent"
    #expect(resolver.resolveTargetBundleID(audibleCandidates: []) == "com.nonexistent")

    box.bundleID = nil
    #expect(resolver.resolveTargetBundleID(audibleCandidates: []) == nil)
  }

  @Test(
    "AudioEngine.isAudibleNow requires healthy process observation and non-empty processObjectIDs")
  func audioEngineIsAudibleNow() {
    let settings = makeCompatSettingsManager()
    let devices = CompatDeviceObs()
    let processes = CompatProcessObs()
    let deviceVolume = CompatDeviceVolume()
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let engine = AudioEngine(
      controller: controller, settingsManager: settings,
      deviceObservations: devices, processObservations: processes,
      deviceVolumeMonitor: deviceVolume, readOutputFailure: { nil })

    let silentApp = makeCompatAudioApp(id: 70, bundleID: "com.test.silent", processObjects: [])
    let activeApp = makeCompatAudioApp(id: 71, bundleID: "com.test.active", processObjects: [99])
    processes.observation = AudioProcessObservationSnapshot(
      activeApps: [silentApp, activeApp], health: .healthy)

    #expect(!engine.isAudibleNow(bundleID: "com.does.not.exist"))
    #expect(!engine.isAudibleNow(bundleID: "com.test.silent"))
    #expect(engine.isAudibleNow(bundleID: "com.test.active"))
  }
}
