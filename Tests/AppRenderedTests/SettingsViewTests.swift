// Independent settings projection/binding tests; no global settings or key registration.
import AppKit
import AppTestSupport
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI
import Testing

@testable import FineTune
@Suite("Settings live bindings")
@MainActor
struct SettingsViewTests {
  @Test("The live-audio field saves the wish and starts/stops the same Root Controller")
  func liveAudioFieldUsesCommonCaptureTransition() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneCaptureSettings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: CaptureSettingsLoginService())
    let runtime = RoutingProbeRuntime()
    let controller = AudioController(
      settings: settings, runtime: runtime, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let root = RootBindings(controller: controller, settings: settings)
    let read = {
      SettingsSnapshot(
        settings: settings.appSettings, isAccessibilityTrusted: false, isMediaKeyOffline: false,
        error: controller.lastFailure?.message, device: testDeviceSettings())
    }
    let actions = SettingsActions(
      updateSettings: root.updateSettings,
      recordShortcut: { _, _ in Issue.record("Capture editing must not register shortcuts.") },
      requestAccessibility: { Issue.record("Capture editing must not request Accessibility.") },
      retryMediaKeys: { Issue.record("Capture editing must not start media keys.") },
      resetAll: root.resetAllSettings,
      device: recordingDeviceSettingsActions { _ in
        Issue.record("Capture editing must not issue device commands.")
      })
    let binding = SettingsBindings(read: read, actions: actions)
      .field(\AppSettings.explicitUserCaptureEnabled)
    _ = FineTuneSettingsView(
      read: read, actions: actions, updates: .unavailable(reason: "No test update service."))
    #expect(!binding.wrappedValue && runtime.requests.isEmpty)
    #expect(root.controller === controller && controller.captureIntent == .none)
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "capture-output", bindingRevision: 1, supportsAutoEQ: false, processingGain: 1,
          volume: 1, isMuted: false)
      ], defaultUID: "capture-output")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: "unit.capture-settings", processID: 72, processRevision: 1,
        displayName: "Capture Settings", bundleID: "unit.capture-settings")
    ])
    #expect(runtime.requests.isEmpty)

    binding.wrappedValue = true
    #expect(settings.appSettings.explicitUserCaptureEnabled && binding.wrappedValue)
    guard case .userInitiated(let session) = controller.captureIntent else {
      Issue.record("The same settings transition must establish capture intent.")
      return
    }
    #expect(session != 0)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("capture-output"))
    #expect(runtime.requests.count == 1 && route.commits.count == 1)
    binding.wrappedValue = false
    #expect(!settings.appSettings.explicitUserCaptureEnabled && !binding.wrappedValue)
    #expect(controller.captureIntent == .none && route.cancelled)
    await controller.shutdown()
    #expect(route.retired && !route.rendering && runtime.requests.count == 1)
    settings.flushSync()
    #expect(settings.lastSaveError == nil)
    let reloaded = SettingsManager(
      directory: directory, launchAtLoginService: CaptureSettingsLoginService())
    #expect(!reloaded.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Changing a field preserves unrelated preferences updated after the binding was created")
  func fieldBindingUsesLatestSettings() {
    let source = SettingsTestSource()
    let theme = source.bindings.field(\AppSettings.appearance)
    source.snapshot.settings.popupSize = .spacious
    source.snapshot.settings.volumeHotkeyStep = .extraFine
    theme.wrappedValue = .dark
    #expect(source.snapshot.settings.appearance == .dark)
    #expect(source.snapshot.settings.popupSize == .spacious)
    #expect(source.snapshot.settings.volumeHotkeyStep == .extraFine)
    #expect(source.events == ["settings"])
  }

  @Test("A previously created binding also reads externally changed preferences")
  func fieldGetterRemainsLive() {
    let source = SettingsTestSource()
    let enabled = source.bindings.field(\AppSettings.mediaKeyControlEnabled)
    source.snapshot.settings.mediaKeyControlEnabled = false
    #expect(!enabled.wrappedValue)
    #expect(source.events.isEmpty)
  }

  @Test("Unified loudness writes both settings while preserving current unrelated fields")
  func unifiedLoudnessBinding() {
    let source = SettingsTestSource()
    source.snapshot.settings.loudnessCompensationEnabled = true
    source.snapshot.settings.loudnessEqualizationEnabled = false
    let unified = source.bindings.unifiedLoudness
    #expect(!unified.wrappedValue)
    source.snapshot.settings.appearance = .light
    unified.wrappedValue = true
    #expect(source.snapshot.settings.loudnessCompensationEnabled)
    #expect(source.snapshot.settings.loudnessEqualizationEnabled)
    #expect(source.snapshot.settings.appearance == .light)
    unified.wrappedValue = false
    #expect(!source.snapshot.settings.loudnessCompensationEnabled)
    #expect(!source.snapshot.settings.loudnessEqualizationEnabled)
  }

  @Test("The saved default-volume preference retains the original direct scalar editing")
  func defaultVolumeBinding() {
    let source = SettingsTestSource()
    source.snapshot.settings.defaultNewAppVolume = 0.25
    let slider = source.bindings.defaultVolume
    #expect(slider.wrappedValue == 0.25)
    slider.wrappedValue = 0.8
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.8)
  }

  @Test("Typed default-volume percentages keep the original ten-percent lower bound")
  func editableDefaultPercentage() {
    let source = SettingsTestSource()
    let field = VolumePercentageField(
      value: source.bindings.defaultVolume, range: 10...100, label: "Default volume")
    field.boundedValue.wrappedValue = 0.02
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.1)
    field.boundedValue.wrappedValue = 0.6
    #expect(source.snapshot.settings.defaultNewAppVolume == 0.6)
  }

  @Test("Shortcut recording and clearing forward the action and value without global registration")
  func shortcutActionsAreExplicit() {
    let source = SettingsTestSource()
    let value = ShortcutCodable(keyCode: 42, modifiers: 256)
    source.actions.recordShortcut(.togglePopup, value)
    #expect(source.lastShortcutAction == .togglePopup)
    #expect(source.lastShortcut == value)
    source.actions.recordShortcut(.targetAppVolumeUp, nil)
    #expect(source.lastShortcutAction == .targetAppVolumeUp)
    #expect(source.lastShortcut == nil)
    #expect(source.events == ["shortcut", "shortcut"])
  }

  @Test("An unavailable alert value never exposes a fabricated zero slider")
  func alertAvailabilityIsExplicit() throws {
    let source = SettingsTestSource()
    #expect(source.bindings.alertVolume == nil)
    source.snapshot.device.canSetAlertVolume = true
    #expect(source.bindings.alertVolume == nil)
    source.snapshot.device.alertVolume = 0.4
    let binding = try #require(source.bindings.alertVolume)
    source.snapshot.device.alertVolume = 0.7
    #expect(abs(binding.wrappedValue - 0.7) < 0.000_001)
    binding.wrappedValue = 0.3
    #expect(source.events == ["alert:0.3"])
    #expect(source.snapshot.device.alertVolume == 0.7)
  }

  @Test("System sounds preserve follow-default intent independently of observed output")
  func systemSoundsBindingSeparatesIntent() {
    let source = SettingsTestSource()
    #expect(source.bindings.systemSounds.wrappedValue == .followDefault)
    source.snapshot.device.followsDefault = false
    #expect(source.bindings.systemSounds.wrappedValue == .unavailable)
    source.snapshot.device.systemOutputUID = "observed-output"
    #expect(source.bindings.systemSounds.wrappedValue == .device("observed-output"))
    source.bindings.systemSounds.wrappedValue = .device("requested-output")
    source.bindings.systemSounds.wrappedValue = .followDefault
    #expect(source.events == ["system-output:requested-output", "system-follow"])
    #expect(source.snapshot.device.systemOutputUID == "observed-output")
  }

  @Test("An available update service supplies live values and explicit actions")
  func updatesUseLiveBindings() {
    var snapshot = SettingsUpdatePresentation(
      automaticallyChecks: true, lastChecked: nil, isChecking: false, error: nil)
    var requests: [String] = []
    let actions = SettingsUpdateActions(
      checkNow: { requests.append("check") },
      setAutomaticChecks: { requests.append("auto:\($0)") })
    let bindings = SettingsUpdateBindings(read: { snapshot }, actions: actions)
    snapshot.automaticallyChecks = false
    #expect(!bindings.automaticChecks.wrappedValue)
    bindings.automaticChecks.wrappedValue = true
    actions.checkNow()
    #expect(requests == ["auto:true", "check"])
    #expect(!snapshot.automaticallyChecks)
  }

  @Test("An unavailable update capability renders without requiring fake actions")
  func unavailableUpdatesRender() {
    _ = NSApplication.shared
    let host = NSHostingView(
      rootView: SettingsUpdatesView(
        capability: .unavailable(
          reason: "No signed rewrite release feed is configured.")))
    host.setFrameSize(NSSize(width: 640, height: 380))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height > 0)
  }

  @Test("The actual General settings component renders offscreen without actions")
  func settingsRenderWithoutEffects() {
    _ = NSApplication.shared
    let source = SettingsTestSource()
    let host = NSHostingView(
      rootView: FineTuneSettingsView(
        read: { source.snapshot }, actions: source.actions,
        updates: .unavailable(reason: "No test release feed is configured.")))
    host.setFrameSize(NSSize(width: 720, height: 560))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 720)
    #expect(host.fittingSize.height == 560)
    #expect(source.events.isEmpty)
  }
}

@MainActor
@Observable
private final class SettingsTestSource {
  var snapshot = SettingsSnapshot(
    settings: AppSettings(), isAccessibilityTrusted: false, isMediaKeyOffline: false, error: nil,
    device: testDeviceSettings())
  var events: [String] = []
  var lastShortcutAction: ShortcutAction?
  var lastShortcut: ShortcutCodable?

  var bindings: SettingsBindings { SettingsBindings(read: { self.snapshot }, actions: actions) }

  var actions: SettingsActions {
    SettingsActions(
      updateSettings: {
        self.snapshot.settings = $0
        self.events.append("settings")
      },
      recordShortcut: {
        self.lastShortcutAction = $0
        self.lastShortcut = $1
        self.events.append("shortcut")
      },
      requestAccessibility: { self.events.append("accessibility") },
      retryMediaKeys: { self.events.append("retry-keys") },
      resetAll: { self.events.append("reset") },
      device: recordingDeviceSettingsActions { self.events.append($0) }
    )
  }
}

// Shared, explicit fixture values/ports for these two test files. No live service is constructed.
func testDeviceSettings() -> DeviceSettingsPresentation {
  DeviceSettingsPresentation(
    systemOutputUID: nil, systemOutputOptions: [], canSetSystemOutput: false, followsDefault: true,
    alertVolume: nil, canSetAlertVolume: false, alertIsApplying: false,
    alertVolumeSilenced: false, error: nil,
    bluetooth: BluetoothPresentation(isPoweredOn: nil, paired: [], error: nil))
}

@MainActor
func recordingDeviceSettingsActions(_ record: @escaping (String) -> Void) -> DeviceSettingsActions {
  DeviceSettingsActions(
    setSystemOutput: { record("system-output:\($0)") },
    setSystemFollowDefault: { record("system-follow") },
    setAlertVolume: { record("alert:\($0)") },
    refreshBluetooth: { record("bluetooth-refresh") },
    connectBluetooth: { record("bluetooth-connect:\($0)") })
}

@MainActor
private final class CaptureSettingsLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
