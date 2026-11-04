import AppKit
@preconcurrency import ApplicationServices
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI

/// The one production assembly. Construction does not start monitors, hotkeys or capture.
@MainActor
final class ProductionRoot {
  let graph: ApplicationGraph
  let devices: AudioDeviceMonitor
  let processes: AudioProcessMonitor
  let output: CoreAudioDeviceVolumeAdapter
  let deviceControl: DeviceControlModel
  let native: NativeAudioRoutingRuntime
  let captureRuntime: CaptureUsageRuntime
  let inputPolicy: InputDevicePolicyController
  let outputPolicy: OutputDevicePolicyController
  let accessibility: SystemAccessibilityTrust
  let mediaKeyStatus: MediaKeyStatus
  let popupVisibility: PopupVisibilityService
  let hud: HUDWindowController
  let mediaKeys: MediaKeyMonitor
  let targetResolver: TargetAppResolver
  let workspaceObservation: WorkspaceTargetObservation
  let keyboard: SystemShortcutRegistration
  private let ddc: DDCVolumeBackend
  private let quit: () -> Void
  private var lastMenuBarDefaultUID: String?
  private lazy var applicationIcons = RootApplicationIconCache(resolve: { bundleID in
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: url.path)
  })

  private lazy var menuBarIcon = RootMenuBarIconCoordinator(
    readBaseline: { [unowned self] in
      let id = output.defaultDeviceID
      return MenuBarIconState.baseline(
        style: graph.settings.appSettings.menuBarIconStyle,
        volume: output.volumes[id] ?? 0, muted: output.muteStates[id] ?? false,
        deviceSymbol: currentMenuBarDeviceSymbol())
    },
    readDeviceSymbol: { [unowned self] in currentMenuBarDeviceSymbol() },
    apply: { [unowned self] image in menuBar.statusItem.button?.image = image.nsImage() },
    clock: .continuous)

  lazy var lifecycle: LifecycleCoordinator = LifecycleCoordinator(
    settings: graph.settings,
    ports: LifecyclePorts(
      start: { [unowned self] in startServices() },
      shutdown: { [unowned self] in try await stopServices() },
      suspendAudio: { [unowned self] in
        inputPolicy.suspend()
        outputPolicy.suspend()
        await graph.controller.shutdown()
      },
      resumeAudio: { [unowned self] in
        output.refreshOutputDeviceStates()
        Self.resumeAudio(
          graph: graph, inputPolicy: inputPolicy, outputPolicy: outputPolicy,
          observeCurrentPolicies: { self.observeDevicePolicies() })
      },
      suspendInput: { [unowned self] in
        menuBarIcon.stop()
        Self.suspendInput(shortcuts: shortcuts, stopMediaKeys: { self.mediaKeys.stop() })
      },
      resumeInput: { [unowned self] in
        menuBarIcon.start()
        Self.resumeInput(shortcuts: shortcuts, refreshMediaKeys: { self.refreshAccessibility() })
      }))

  lazy var presentation = RootPresentation(
    graph: graph, devices: deviceControl, native: native, accessibility: accessibility,
    mediaKeyStatus: mediaKeyStatus, lifecycle: lifecycle,
    hasCaptureUsageDescription: captureRuntime.isConfigured,
    applicationIcon: { [unowned self] in applicationIcons.icon(for: $0) })

  lazy var menuBar = MenuBarPresentation(
    visibility: popupVisibility,
    willShow: { [unowned self] in deviceControl.backendActions.refreshBluetooth() },
    content: { [unowned self] in
      MixerView(
        read: { self.presentation.mixerSnapshot() }, actions: mixerActions,
        profiles: graph.autoEQAutomation.makeMixerInterface(), quit: quit)
    })

  lazy var shortcuts = ShortcutsRegistry(
    settings: graph.settings, popupController: menuBar.popupController, resolver: targetResolver,
    audioEngine: graph.engine, hud: hud, keyboard: keyboard)

  private lazy var settingsWindow: NSWindow = {
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: FineTuneSettingsView(
          read: { [presentation = self.presentation] in presentation.settingsSnapshot() },
          actions: settingsActions,
          updates: .unavailable(
            reason: "Automatic updates are not configured for this rewrite build."))))
    window.title = "FineTune Rewrite Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.center()
    return window
  }()

  init(directory: URL, usageDescription: String?, quit: @escaping () -> Void) throws {
    let settings = SettingsManager(directory: directory)
    let profiles = try AutoEQProfileRepository(
      directory: directory.appendingPathComponent("Profiles", isDirectory: true),
      cache: AutoEQProfileCache())
    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    let reader = CoreAudioDevicePropertyReader()
    let writer = CoreAudioDevicePropertyWriter()
    let observer = CoreAudioDevicePropertyObserver()
    let ddc = DDCVolumeBackend(
      transport: SystemIOAVDDCTransport(), preferences: settings,
      candidates: {
        guard devices.observation.health == .healthy else {
          throw DeviceBackendError.operationFailed("Audio device discovery is unavailable.")
        }
        return devices.outputDevices.map {
          DDCAudioCandidate(uid: $0.uid, name: $0.name, transport: $0.transportType)
        }
      }, displayChanges: SystemDisplayParameterObserver(), clock: .continuous)
    let output = CoreAudioDeviceVolumeAdapter(
      deviceProvider: devices, settingsManager: settings, reader: reader, writer: writer,
      observer: observer, ddcController: ddc)
    let inputPolicy = InputDevicePolicyController(
      settings: settings,
      setDefaultInput: { uid in
        guard let device = devices.inputDevice(for: uid) else {
          throw DeviceBackendError.unavailableDevice(uid)
        }
        guard output.setDefaultInputDevice(device.id) else {
          throw output.lastError ?? DeviceBackendError.operationFailed("Couldn’t select the input.")
        }
      })
    let outputPolicy = OutputDevicePolicyController(
      settings: settings,
      setDefaultOutput: { uid in
        guard let device = devices.device(for: uid) else {
          throw DeviceBackendError.unavailableDevice(uid)
        }
        guard output.setDefaultDevice(device.id) else {
          throw output.lastError
            ?? DeviceBackendError.operationFailed("Couldn’t select the output.")
        }
      })
    let deviceControl = DeviceControlModel(
      settings: settings, devices: devices, output: output,
      input: InputDeviceBackend(
        deviceProvider: devices, reader: reader, writer: writer, observer: observer),
      systemSounds: SystemSoundBackend(
        deviceProvider: devices, reader: reader, writer: writer, observer: observer),
      alertVolume: AlertVolumeBackend(scriptRunner: SystemDeviceScriptRunner(), clock: .continuous),
      bluetooth: BluetoothDeviceBackend(
        transport: SystemBluetoothDeviceTransport(), clock: .continuous),
      ddc: ddc, reader: reader,
      selectPreferredInput: { try inputPolicy.selectPreferredInput(uid: $0) },
      inputPreferencesDidChange: { inputPolicy.settingsDidChange() },
      selectDefaultOutput: { try outputPolicy.selectDefaultOutput(uid: $0) },
      outputPreferencesDidChange: { outputPolicy.settingsDidChange() })
    let native = NativeAudioRoutingRuntime(resolveApp: { identifier, revision in
      try processes.resolveApp(identifier: identifier, processRevision: revision)
    })
    let captureRuntime = CaptureUsageRuntime(runtime: native, usageDescription: usageDescription)
    let graph = ApplicationGraph(
      settings: settings, profiles: profiles, devices: devices, processes: processes,
      volumes: output, runtime: captureRuntime,
      readOutputFailure: { output.defaultOutputReadFailure },
      readDefaultRoutingDecision: {
        outputPolicy.routingDecision()
      },
      deviceCommand: deviceControl.perform)
    let accessibility = SystemAccessibilityTrust()
    let status = MediaKeyStatus()
    let visibility = PopupVisibilityService()
    let hud = HUDWindowController(
      settingsManager: settings, mediaKeyStatus: status, popupVisibility: visibility)
    let media = MediaKeyMonitor(
      decoder: IOKitMediaKeyDecoder(), settingsManager: settings, accessibility: accessibility,
      hudController: hud, popupVisibility: visibility, mediaKeyStatus: status,
      tapInstaller: SystemMediaKeyTap(),
      readDevice: {
        let id = output.defaultDeviceID
        guard output.hasCurrentDefaultOutput,
          let device = devices.outputDevices.first(where: { $0.id == id }),
          let gain = output.volumes[id], let muted = output.muteStates[id]
        else { return nil }
        return MediaKeyDeviceSnapshot(
          id: id, tier: output.outputVolumeBackend(for: id), name: device.name, gain: gain,
          muted: muted)
      },
      writeVolume: { id, gain in
        guard let device = devices.outputDevices.first(where: { $0.id == id }) else { return false }
        graph.controller.perform(.setRawDeviceGain(scope: .output, uid: device.uid, gain: gain))
        return graph.controller.commandFailure == nil
      },
      writeMute: { id, muted in
        guard let device = devices.outputDevices.first(where: { $0.id == id }) else { return false }
        graph.controller.perform(.setDeviceMuted(scope: .output, uid: device.uid, muted: muted))
        return graph.controller.commandFailure == nil
      })
    media.feedbackPlayer = VolumeFeedbackPlayer()
    let resolver = TargetAppResolver(
      ownBundleID: Bundle.main.bundleIdentifier ?? "com.finetune-rewrite",
      frontmostBundleIDProvider: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })
    self.graph = graph
    self.devices = devices
    self.processes = processes
    self.output = output
    self.deviceControl = deviceControl
    self.native = native
    self.captureRuntime = captureRuntime
    self.inputPolicy = inputPolicy
    self.outputPolicy = outputPolicy
    self.accessibility = accessibility
    mediaKeyStatus = status
    popupVisibility = visibility
    self.hud = hud
    mediaKeys = media
    targetResolver = resolver
    workspaceObservation = WorkspaceTargetObservation(resolver: resolver)
    keyboard = SystemShortcutRegistration()
    self.ddc = ddc
    self.quit = quit
    mediaKeys.iconCoordinator = menuBarIcon
  }

  private func startServices() {
    primeApplicationIcons()
    lifecycle.observeWhileStarted(
      read: { [weak settings = graph.settings] in
        _ = settings?.getPinnedAppInfo()
        _ = settings?.getIgnoredAppInfo()
      },
      onChange: { [weak self] in self?.primeApplicationIcons() })
    // Created inside the coordinator's current generation, never while it is still idle.
    devices.onObservationChanged = lifecycle.callbackWhileRunning { [weak self] in
      self?.devicesChanged()
    }
    processes.onObservationChanged = lifecycle.callbackWhileRunning { [weak self] in
      self?.graph.engine.ingestObservations()
    }
    let levels = lifecycle.callbackWhileRunning { [weak self] in
      self?.graph.engine.refreshDeviceLevels()
      self?.updateMenuBarIcon()
    }
    output.onVolumeChanged = { _, _ in levels() }
    output.onMuteChanged = { _, _ in levels() }
    let ddcChanged = lifecycle.callbackWhileRunning { [weak self] in
      self?.output.refreshAfterDDCProbe()
      self?.presentation.invalidate()
    }
    ddc.onChange = ddcChanged
    deviceControl.onChange = { [weak presentation] in presentation?.invalidate() }
    native.onCleanupFailure = { [weak presentation] _ in presentation?.invalidate() }
    devices.start()
    output.start()
    deviceControl.start()
    // Local selected corrections are restored synchronously, before process ingestion can prepare audio.
    _ = graph.autoEQAutomation.start()
    processes.start()
    observeDevicePolicies()
    graph.engine.ingestObservations()
    workspaceObservation.start()
    shortcuts.start()
    refreshAccessibility()
    hud.volumeWriter = { [weak self] fraction in
      guard let self, let uid = output.defaultDeviceUID, output.hasCurrentDefaultOutput else {
        return
      }
      graph.controller.perform(
        .setDeviceGain(
          scope: .output, uid: uid,
          gain: VolumeMapping.systemGain(
            forSliderFraction: fraction,
            tier: output.outputVolumeBackend(for: output.defaultDeviceID))))
    }
    lastMenuBarDefaultUID = output.hasCurrentDefaultOutput ? output.defaultDeviceUID : nil
    menuBarIcon.start()
    trackDefaultObservations()
    lifecycle.observeWhileStarted(
      read: { [weak settings = graph.settings] in
        _ = settings?.appSettings.menuBarIconStyle
        _ = settings?.devicePriorityOrder
        _ = settings?.deviceIconOverrides
      },
      onChange: { [weak self] in self?.updateMenuBarIcon() })
  }

  static func suspendInput(
    shortcuts: ShortcutsRegistry, stopMediaKeys: @MainActor () -> Void
  ) {
    stopMediaKeys()
    shortcuts.stop()
  }

  static func resumeInput(
    shortcuts: ShortcutsRegistry, refreshMediaKeys: @MainActor () -> Void
  ) {
    refreshMediaKeys()
    shortcuts.start()
  }

  static func resumeAudio(
    graph: ApplicationGraph, inputPolicy: InputDevicePolicyController,
    outputPolicy: OutputDevicePolicyController,
    observeCurrentPolicies: @MainActor () -> Void
  ) {
    observeCurrentPolicies()
    graph.engine.ingestObservations()
    inputPolicy.resume()
    outputPolicy.resume()
    graph.engine.refreshDeviceLevels()
    graph.controller.resume()
  }

  private func trackDefaultObservations() {
    lifecycle.observeWhileStarted(
      read: { [weak output, weak outputPolicy] in
        _ = output?.defaultDeviceUID
        _ = output?.defaultInputDeviceUID
        _ = output?.defaultOutputReadFailure
        _ = output?.defaultInputReadFailure
        _ = outputPolicy?.intendedDefaultUID
      },
      onChange: { [weak self] in
        guard let self else { return }
        // The lifecycle re-arms first; fanout only reads cached producer state.
        observeDevicePolicies()
        deviceControl.settingsDidChange()
        graph.engine.refreshDeviceLevels()
        let currentUID = output.hasCurrentDefaultOutput ? output.defaultDeviceUID : nil
        if let previous = lastMenuBarDefaultUID, let currentUID, previous != currentUID {
          menuBarIcon.flashDevice()
        }
        lastMenuBarDefaultUID = currentUID
        updateMenuBarIcon()
        presentation.invalidate()
      })
  }

  private func devicesChanged() {
    output.refreshOutputDeviceStates()
    deviceControl.devicesDidChange()
    graph.autoEQAutomation.devicesDidChange()
    observeDevicePolicies()
    graph.engine.ingestObservations()
    updateMenuBarIcon()
  }

  static func devicePolicyFailure(
    health: AudioObservationHealth, defaultReadFailure: String?
  ) -> String? {
    let discoveryFailure: String?
    switch health {
    case .notStarted: discoveryFailure = "Audio device discovery hasn’t started."
    case .failed(let failure): discoveryFailure = failure
    case .healthy: discoveryFailure = nil
    }
    if let discoveryFailure, let defaultReadFailure, discoveryFailure != defaultReadFailure {
      return "\(discoveryFailure)\n\(defaultReadFailure)"
    }
    return defaultReadFailure ?? discoveryFailure
  }

  private func observeDevicePolicies() {
    let snapshot = devices.observation
    inputPolicy.observe(
      availableUIDs: snapshot.inputDevices.map(\.uid), defaultUID: output.defaultInputDeviceUID,
      builtInUIDs: Set(snapshot.inputDevices.filter { $0.transportType == .builtIn }.map(\.uid)),
      bluetoothUIDs: Set(
        snapshot.inputDevices.filter {
          $0.transportType == .bluetooth || $0.transportType == .bluetoothLE
        }.map(\.uid)),
      failure: Self.devicePolicyFailure(
        health: snapshot.health, defaultReadFailure: output.defaultInputReadFailure))
    outputPolicy.observe(
      availableUIDs: snapshot.outputDevices.map(\.uid), defaultUID: output.defaultDeviceUID,
      bluetoothUIDs: Set(
        snapshot.outputDevices.filter {
          $0.transportType == .bluetooth || $0.transportType == .bluetoothLE
        }.map(\.uid)),
      failure: Self.devicePolicyFailure(
        health: snapshot.health, defaultReadFailure: output.defaultOutputReadFailure))
  }

  private func stopServices() async throws {
    menuBarIcon.stop()
    lastMenuBarDefaultUID = nil
    mediaKeys.stop()
    shortcuts.stop()
    workspaceObservation.stop()
    inputPolicy.suspend()
    outputPolicy.suspend()
    graph.autoEQAutomation.stop()
    await graph.controller.shutdown()
    await deviceControl.stop()
    output.stop()
    processes.stop()
    devices.stop()
    hud.shutdown()
    try Self.checkControllerCleanup(graph.controller)
  }

  static func checkControllerCleanup(_ controller: AudioController) throws {
    // A retired ACK releases that owned route; diagnostics remain historical, not global debt.
    for observation in controller.routeObservations.values where observation.phase != .retired {
      if let failure = observation.cleanupFailure { throw failure }
    }
  }

  func refreshAccessibility() {
    accessibility.refresh()
    mediaKeys.reconcile()
    presentation.invalidate()
  }

  func openSettings() {
    if popupVisibility.isVisible { menuBar.toggle() }
    settingsWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func settingsDidChange() {
    // The actual model forwards both required policy settings callbacks; Root owns no policy branch.
    deviceControl.settingsDidChange()
    mediaKeys.reconcile()
    updateMenuBarIcon()
    presentation.invalidate()
  }

  private var settingsActions: SettingsActions {
    SettingsActions(
      updateSettings: { [unowned self] settings in
        graph.bindings.updateSettings(settings)
        settingsDidChange()
      },
      recordShortcut: { [unowned self] action, shortcut in
        var settings = graph.settings.appSettings
        settings.customShortcuts[action.rawValue] = shortcut
        graph.bindings.updateSettings(settings)
        shortcuts.stop()
        shortcuts.start()
        settingsDidChange()
      },
      requestAccessibility: { [unowned self] in
        let options =
          [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibility()
      },
      retryMediaKeys: { [unowned self] in refreshAccessibility() },
      resetAll: { [unowned self] in
        graph.bindings.resetAllSettings()
        shortcuts.stop()
        for action in ShortcutAction.allCases { keyboard.setShortcut(nil, for: action.stableID) }
        shortcuts.start()
        settingsDidChange()
      }, device: deviceControl.backendActions)
  }

  private func primeApplicationIcons() {
    let saved = graph.settings.getPinnedAppInfo() + graph.settings.getIgnoredAppInfo()
    applicationIcons.prime(bundleIDs: Set(saved.compactMap(\.bundleID)))
    presentation.invalidate()
  }

  static func activateApplication(
    bundleURL: URL?, activate: () -> Bool,
    reopen: (URL, @escaping @MainActor (String?) -> Void) -> Void,
    reportFailure: @escaping @MainActor (String?) -> Void
  ) {
    guard let bundleURL else {
      reportFailure(activate() ? nil : "The application could not be activated.")
      return
    }
    reportFailure(nil)
    reopen(bundleURL, reportFailure)
  }

  private var mixerActions: MixerActions {
    MixerActions(
      app: graph.bindings.appActions(activate: { [unowned self] identifier in
        guard processes.observation.health == .healthy,
          let app = processes.activeApps.first(where: { $0.persistenceIdentifier == identifier }),
          let running = NSRunningApplication(processIdentifier: app.id)
        else { return }
        let applicationName = app.name
        Self.activateApplication(
          bundleURL: running.bundleURL, activate: { running.activate() },
          reopen: { url, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
              let failure = error.map {
                "Unable to reopen \(applicationName): \($0.localizedDescription)"
              }
              Task { @MainActor in completion(failure) }
            }
          },
          reportFailure: { [weak presentation = self.presentation] in
            presentation?.applicationActivationFailure = $0
          })
      }), device: presentation.deviceActions,
      openSettings: { [unowned self] in openSettings() },
      close: { [unowned self] in menuBar.toggle() }, backend: deviceControl.backendActions,
      requestCapturePermission: { [unowned self] in graph.controller.perform(.requestCaptureStart)
      },
      openCaptureSettings: {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
      })
  }

  private func updateMenuBarIcon() { menuBarIcon.refresh() }

  private func currentMenuBarDeviceSymbol() -> String {
    Self.menuBarDeviceSymbol(
      outputDevices: devices.observation.health == .healthy ? devices.outputDevices : [],
      defaultDeviceID: output.hasCurrentDefaultOutput
        ? output.defaultDeviceID : kAudioObjectUnknown,
      priorityOrder: graph.settings.devicePriorityOrder,
      overrideForUID: { graph.settings.getDeviceIconOverride(for: $0) })
  }

  static func menuBarDeviceSymbol(
    outputDevices: [AudioDevice], defaultDeviceID: AudioDeviceID,
    priorityOrder: [String], overrideForUID: (String) -> String?
  ) -> String {
    MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: priorityOrder, outputDevices: outputDevices, defaultDeviceID: defaultDeviceID,
      overrideForUID: overrideForUID, isDeviceAvailable: { $0.id != kAudioObjectUnknown },
      symbolForDevice: {
        DeviceIconSymbol.iconSymbol(forName: $0.name, transport: $0.transportType)
      }, symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol })
  }

  func closePresentation() {
    settingsWindow.orderOut(nil)
    menuBar.shutdown()
  }
}
