// Independent rewrite tests: live projection, identity, binding and action guarantees.
// No application bootstrap, storage, permissions, or audio runtime is started.
import AppKit
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI
import Testing

@testable import FineTune

@Suite("Mixer projection and actions")
@MainActor
struct MixerTests {
  @Test("An app slider reads live gain and writes square-law gain by persistent identity")
  func liveAppVolumeBinding() {
    let source = MixerTestSource()
    let app = source.snapshot.apps[0]
    let binding = source.bindings.appVolume(app)
    #expect(binding.wrappedValue == 0.5)
    source.snapshot.apps[0].gain = 0.81
    #expect(abs(binding.wrappedValue - 0.9) < 0.000_001)
    binding.wrappedValue = 0.4
    #expect(source.lastAppID == "com.example.player")
    #expect(abs((source.lastGain ?? 0) - 0.16) < 0.000_001)
  }

  @Test("Inactive pinned apps use the same gain, mute and boost actions")
  func inactiveActionsRetainIdentity() {
    let source = MixerTestSource()
    let app = source.snapshot.apps[0]
    #expect(!app.isActive)
    source.bindings.appMute(app).wrappedValue = true
    #expect(source.lastAppID == app.id)
    #expect(source.lastBool == true)
    source.bindings.appBoost(app).wrappedValue = .x3
    #expect(source.lastAppID == app.id)
    #expect(source.lastBoost == .x3)
  }

  @Test("Edit mode exposes ignored and unpinned inactive metadata without changing saved values")
  func appVisibilityIsPresentationOnly() {
    let source = MixerTestSource()
    var ignored = source.snapshot.apps[0]
    ignored.id = "com.example.ignored"
    ignored.isIgnored = true
    var inactive = source.snapshot.apps[0]
    inactive.id = "com.example.inactive"
    inactive.isPinned = false
    source.snapshot.apps += [ignored, inactive]
    #expect(source.bindings.visibleApps(editing: false).map(\.id) == ["com.example.player"])
    #expect(source.bindings.visibleApps(editing: true).count == 3)
    #expect(source.events.isEmpty)
  }

  @Test(
    "App display order groups pinned active, pinned inactive and active apps before ignored metadata"
  )
  func appDisplayOrder() {
    let source = MixerTestSource()
    let seed = source.snapshot.apps[0]
    func app(_ name: String, active: Bool, pinned: Bool, ignored: Bool = false)
      -> MixerAppPresentation
    {
      var app = seed
      app.id = name
      app.name = name
      app.isActive = active
      app.isPinned = pinned
      app.isIgnored = ignored
      return app
    }
    source.snapshot.apps = [
      app("Unpinned", active: true, pinned: false),
      app("Ignored", active: true, pinned: true, ignored: true),
      app("alpha inactive", active: false, pinned: true),
      app("Zulu active", active: true, pinned: true),
      app("Beta active", active: true, pinned: true),
      app("Saved inactive", active: false, pinned: false),
    ]
    #expect(
      source.bindings.visibleApps(editing: false).map(\.id) == [
        "Beta active", "Zulu active", "alpha inactive", "Unpinned",
      ])
    #expect(
      source.bindings.visibleApps(editing: true).map(\.id) == [
        "Beta active", "Zulu active", "alpha inactive", "Unpinned", "Saved inactive", "Ignored",
      ])
    #expect(source.events.isEmpty)
  }

  @Test("Hidden defaults remain visible and an all-hidden list never means no connected devices")
  func deviceVisibilityKeepsDefaultAndFallback() {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].isHidden = true
    #expect(source.bindings.devices(scope: .output, editing: false).map(\.id) == ["output-uid"])
    source.snapshot.outputDevices[0].isDefault = false
    #expect(source.bindings.devices(scope: .output, editing: false).map(\.id) == ["output-uid"])
    var visible = source.snapshot.outputDevices[0]
    visible.device = AudioDevice(
      id: 103, uid: "visible-output", name: "Visible", icon: nil, supportsAutoEQ: false)
    visible.isHidden = false
    source.snapshot.outputDevices.append(visible)
    #expect(source.bindings.devices(scope: .output, editing: false).map(\.id) == ["visible-output"])
    #expect(source.bindings.devices(scope: .output, editing: true).count == 2)
  }

  @Test("Input and output device writes keep their own scope and backend curve")
  func deviceBindingsKeepScope() throws {
    let source = MixerTestSource()
    let output = source.snapshot.outputDevices[0]
    let input = source.snapshot.inputDevices[0]
    let outputSlider = try #require(source.bindings.deviceRow(output, scope: .output).slider)
    outputSlider.wrappedValue = 0.5
    #expect(source.lastDeviceScope == .output)
    #expect(source.lastDeviceUID == "output-uid")
    #expect(source.lastGain == 0.25)
    let inputSlider = try #require(source.bindings.deviceRow(input, scope: .input).slider)
    inputSlider.wrappedValue = 0.5
    #expect(source.lastDeviceScope == .input)
    #expect(source.lastDeviceUID == "input-uid")
    #expect(source.lastGain == 0.5)
  }

  @Test(
    "A displayed zero mute click requests half-slider once, including tiny nonzero gain",
    arguments: [VolumeControlTier.hardware, .ddc, .software], [Float(0), Float(0.000_001)])
  func zeroDisplayMuteRestoresHalfSlider(backend: VolumeControlTier, volume: Float) throws {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].backend = backend
    source.snapshot.outputDevices[0].volume = volume
    let device = source.snapshot.outputDevices[0]
    let row = source.bindings.deviceRow(device, scope: .output)
    let slider = try #require(row.slider)
    #expect(Int((slider.wrappedValue * 100).rounded()) == 0)
    row.onMuteToggle()
    #expect(source.events == ["device-volume"])
    #expect(source.lastDeviceScope == .output && source.lastDeviceUID == device.id)
    #expect(source.lastGain == (backend == .software ? 0.25 : 0.5))
    #expect(source.lastBool == nil)
  }

  @Test(
    "Zero volume-only input restores linear half-slider without inventing or writing mute",
    arguments: [Float(0), Float(0.000_001)])
  func zeroVolumeOnlyInputDoesNotInventMute(volume: Float) {
    let source = MixerTestSource()
    source.snapshot.inputDevices[0].backend = .software
    source.snapshot.inputDevices[0].volume = volume
    source.snapshot.inputDevices[0].isMuted = nil
    source.snapshot.inputDevices[0].canSetMute = false
    let device = source.snapshot.inputDevices[0]
    source.bindings.deviceRow(device, scope: .input).onMuteToggle()
    #expect(source.events == ["device-volume"])
    #expect(source.lastDeviceScope == .input && source.lastDeviceUID == device.id)
    #expect(source.lastGain == 0.5 && source.lastBool == nil)
    #expect(source.snapshot.inputDevices[0].isMuted == nil)
  }

  @Test("A known read-only mute blocks composed recovery even when zero volume is writable")
  func knownReadOnlyMutePreventsComposedRecovery() {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].volume = 0
    source.snapshot.outputDevices[0].isMuted = true
    let uid = source.snapshot.outputDevices[0].id
    let earlierRow = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    source.snapshot.outputDevices[0].canSetMute = false
    let row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(row.canSetVolume && row.isMuted == true)
    #expect(!row.canToggleMute && row.displayedMuteState == true)
    earlierRow.onMuteToggle()
    source.bindings.toggleDeviceMute(scope: .output, uid: uid)
    #expect(source.events.isEmpty)
    #expect(source.lastGain == nil && source.lastBool == nil)
    #expect(source.snapshot.outputDevices[0].isMuted == true)
  }

  @Test("Mute callbacks resolve latest volume, backend and mute instead of their captured row")
  func deviceMuteReadsLatestValues() {
    let source = MixerTestSource()
    let row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    source.snapshot.outputDevices[0].volume = 0.000_001
    source.snapshot.outputDevices[0].backend = .hardware
    row.onMuteToggle()
    #expect(source.events == ["device-volume"] && source.lastGain == 0.5)
    source.events.removeAll()
    source.lastGain = nil
    source.snapshot.outputDevices[0].volume = 0.4
    source.snapshot.outputDevices[0].isMuted = true
    row.onMuteToggle()
    #expect(source.events == ["device-mute"] && source.lastBool == false)
    #expect(source.lastGain == nil)
  }

  @Test("Zero and unknown row presentation keep unavailable capabilities and actual mute distinct")
  func deviceMutePresentationKeepsUnknownState() {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].volume = 0.000_001
    source.snapshot.outputDevices[0].isMuted = nil
    source.snapshot.outputDevices[0].canSetMute = false
    var row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(row.displayedPercentage == 0 && row.displayedMuteState == true && row.canToggleMute)
    #expect(row.isMuted == nil)
    source.snapshot.outputDevices[0].canSetVolume = false
    row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(!row.canToggleMute && row.displayedMuteState == true)
    row.onMuteToggle()
    #expect(source.events.isEmpty)
    source.snapshot.outputDevices[0].volume = nil
    row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(row.displayedPercentage == nil && row.displayedMuteState == nil && !row.canToggleMute)
    row.onMuteToggle()
    source.snapshot.outputDevices[0].volume = 0.5
    source.snapshot.outputDevices[0].canSetVolume = true
    source.snapshot.outputDevices[0].canSetMute = true
    row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(row.displayedMuteState == nil && !row.canToggleMute)
    row.onMuteToggle()
    #expect(source.events.isEmpty && source.snapshot.outputDevices[0].isMuted == nil)
  }

  @Test(
    "Unknown volume still permits an independently known writable mute bit",
    arguments: [false, true])
  func ordinaryMuteWithUnknownVolume(isMuted: Bool) {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].volume = nil
    source.snapshot.outputDevices[0].isMuted = isMuted
    source.snapshot.outputDevices[0].canSetVolume = false
    let row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    #expect(
      row.displayedPercentage == nil && row.displayedMuteState == isMuted && row.canToggleMute)
    row.onMuteToggle()
    #expect(source.events == ["device-mute"] && source.lastBool == !isMuted)
    #expect(source.lastGain == nil)
  }

  @Test("A disappeared device cannot supply stale mute state to a delayed click")
  func disappearedDeviceMuteDoesNotFallback() {
    let source = MixerTestSource()
    let row = source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output)
    source.snapshot.outputDevices.removeAll()
    row.onMuteToggle()
    #expect(source.events.isEmpty)
  }

  @Test("The shared keyboard device entry requests one gain operation without a trailing raw mute")
  func sharedDeviceMuteEntryUsesFreshUID() {
    let source = MixerTestSource()
    let uid = source.snapshot.outputDevices[0].id
    source.snapshot.outputDevices[0].volume = 0
    source.bindings.toggleDeviceMute(scope: .output, uid: uid)
    #expect(source.events == ["device-volume"] && source.lastGain == 0.25 && source.lastBool == nil)
    source.events.removeAll()
    source.snapshot.outputDevices[0].volume = 0.4
    source.snapshot.outputDevices[0].canSetMute = false
    source.bindings.toggleDeviceMute(scope: .output, uid: uid)
    #expect(source.events.isEmpty)
  }

  @Test("The actual row preserves volume-only input and has no unknown or read-only binding")
  func deviceRowCapabilitiesAreIndependent() throws {
    let source = MixerTestSource()
    var input = source.snapshot.inputDevices[0]
    input.isMuted = nil
    input.canSetMute = false
    let row = source.bindings.deviceRow(input, scope: .input)
    #expect(row.isInput)
    #expect(!row.canSetMute)
    let slider = try #require(row.slider)
    slider.wrappedValue = 0.6
    #expect(source.lastDeviceScope == .input)
    #expect(source.lastGain == 0.6)
    input.volume = nil
    #expect(source.bindings.deviceRow(input, scope: .input).slider == nil)
    input.volume = 0.4
    input.canSetVolume = false
    #expect(source.bindings.deviceRow(input, scope: .input).slider == nil)
  }

  @Test("A band edit preserves the latest other bands and the independent EQ enable flag")
  func eqBandBindingUsesLatestCurve() {
    let source = MixerTestSource()
    let app = source.snapshot.apps[0]
    let band = source.bindings.eqBand(app, index: 2)
    source.snapshot.apps[0].eqSettings.bandGains[7] = 5
    source.snapshot.apps[0].eqSettings.isEnabled = false
    band.wrappedValue = 4
    #expect(source.lastEQ?.bandGains[2] == 4)
    #expect(source.lastEQ?.bandGains[7] == 5)
    #expect(source.lastEQ?.isEnabled == false)
  }

  @Test("Applying a preset changes its curve without turning disabled EQ on")
  func presetPreservesEnableState() {
    let source = MixerTestSource()
    source.snapshot.apps[0].eqSettings.isEnabled = false
    source.bindings.applyPreset(.bassBoost, to: source.snapshot.apps[0])
    #expect(source.lastEQ?.bandGains == EQPreset.bassBoost.settings.bandGains)
    #expect(source.lastEQ?.isEnabled == false)
  }

  @Test("Default, explicit and multi selections remain distinct requests")
  func routeRequestsAreExplicit() {
    let source = MixerTestSource()
    let app = source.snapshot.apps[0]
    source.bindings.followDefault(app)
    #expect(source.events.last == "follow-default")
    source.bindings.selectRoute(app, mode: .single, uids: ["missing-device"])
    #expect(source.lastMode == .single)
    #expect(source.lastUIDs == ["missing-device"])
    source.bindings.selectRoute(app, mode: .multi, uids: ["output-uid", "missing-device"])
    #expect(source.lastMode == .multi)
    #expect(source.lastUIDs == ["output-uid", "missing-device"])
  }

  @Test("A missing desired output is displayed as unavailable, not as system default")
  func missingDesiredOutputIsVisible() {
    let source = MixerTestSource()
    var app = source.snapshot.apps[0]
    app.isFollowingDefault = false
    app.selectedDeviceUIDs = ["missing-device"]
    #expect(source.bindings.routeLabel(app).contains("missing-device"))
    #expect(!source.bindings.routeLabel(app).contains("System Default"))
  }

  @Test("A device removed while a row is being dismissed cannot change its command identity")
  func disappearingDeviceKeepsCommandAddress() throws {
    let source = MixerTestSource()
    let device = source.snapshot.inputDevices[0]
    let binding = try #require(source.bindings.deviceRow(device, scope: .input).slider)
    source.snapshot.inputDevices = []
    binding.wrappedValue = 0.3
    #expect(source.lastDeviceScope == .input)
    #expect(source.lastDeviceUID == device.id)
    #expect(source.lastGain == 0.3)
  }

  @Test("A first action key wakes and acts on the default row in the same press")
  func keyboardWakeAndAct() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    #expect(
      keyboard.process(.right(shift: true), navigation: navigation, defaultOutputUID: nil)
        == .adjust(.app(persistenceID: "player"), isUp: true, shift: true))
    #expect(keyboard.selectedRow == .app(persistenceID: "player"))
  }

  @Test("An arrow wakes without moving, then traverses without wrapping")
  func keyboardWakeAndTraverse() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(
      activeDevices: [], appPersistenceIDs: ["first", "second"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    #expect(keyboard.process(.down, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.selectedRow == .app(persistenceID: "first"))
    _ = keyboard.process(.down, navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.selectedRow == .app(persistenceID: "second"))
    _ = keyboard.process(.down, navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.selectedRow == .app(persistenceID: "second"))
  }

  @Test("Keyboard percentage entry is a transient draft until Return")
  func keyboardPercentageDraft() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(8), navigation: navigation, defaultOutputUID: nil)
    _ = keyboard.process(.digit(0), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.percentageDraft == "80")
    #expect(
      keyboard.process(.activate, navigation: navigation, defaultOutputUID: nil)
        == .setPercentage(.app(persistenceID: "player"), 80))
    #expect(keyboard.percentageDraft == nil)
  }

  @Test("Escape cancels percentage entry before closing the popup")
  func keyboardPercentageCancel() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(3), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.process(.cancel, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.percentageDraft == nil)
    #expect(keyboard.process(.cancel, navigation: navigation, defaultOutputUID: nil) == .close)
  }

  @Test("Space is consumed during percentage entry rather than committing or activating")
  func spaceDoesNotCommitPercentage() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(8), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.process(.space, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.percentageDraft == "8")
  }

  @Test("Typed app percentages share the real slider binding and clamp to its range")
  func editableAppPercentage() {
    let source = MixerTestSource()
    let field = VolumePercentageField(
      value: source.bindings.appVolume(source.snapshot.apps[0]), range: 0...100,
      label: "Player volume")
    field.boundedValue.wrappedValue = 0.8
    #expect(abs((source.lastGain ?? 0) - 0.64) < 0.000_001)
    field.boundedValue.wrappedValue = 1.5
    #expect(source.lastGain == 1)
  }

  @Test("Unknown Bluetooth status and read failure render without probing or connecting")
  func bluetoothAvailabilityRendersWithoutEffects() {
    _ = NSApplication.shared
    var bluetooth = testDeviceSettings().bluetooth
    bluetooth.error = "Bluetooth status could not be read."
    var requests: [String] = []
    let host = NSHostingView(
      rootView: MixerBluetoothSection(
        read: { bluetooth }, actions: recordingDeviceSettingsActions { requests.append($0) }))
    host.setFrameSize(NSSize(width: 430, height: 160))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height > 0)
    #expect(requests.isEmpty)
  }

  @Test("Selecting an AutoEQ profile targets one device and enables the new selection")
  func profileSelectionKeepsDeviceIdentity() {
    let source = MixerProfileTestSource()
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    bindings.choose(
      MixerProfileChoice(id: "catalog-profile", name: "Headphones", detail: "Measured"))
    #expect(source.lastDeviceUID == "headphones-a")
    #expect(source.lastSelection == AutoEQSelection(profileID: "catalog-profile", isEnabled: true))
    bindings.clear()
    #expect(source.lastDeviceUID == "headphones-a")
    #expect(source.lastSelection == nil)
  }

  @Test("A missing profile remains named and enabling it preserves its desired identity")
  func missingProfileIsNotReplacedByFlat() {
    let source = MixerProfileTestSource()
    source.snapshot.selection = AutoEQSelection(profileID: "offline-profile", isEnabled: false)
    source.snapshot.isMissing = true
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    #expect(bindings.selectionLabel.contains("offline-profile"))
    #expect(!bindings.enabled.wrappedValue)
    bindings.enabled.wrappedValue = true
    #expect(source.lastSelection == AutoEQSelection(profileID: "offline-profile", isEnabled: true))
    #expect(source.snapshot.isMissing)
  }

  @Test("Favorite filtering is requested from the real catalog before its result limit")
  func profileQueryForwardsFavoriteConstraint() {
    let source = MixerProfileTestSource()
    let results = source.interface.search("specific headphones", true)
    #expect(source.lastQuery == "specific headphones")
    #expect(source.lastFavoritesOnly == true)
    #expect(results.entries.map(\.id) == ["catalog-profile"])
    let bindings = MixerProfileBindings(deviceUID: "headphones-a", interface: source.interface)
    bindings.toggleFavorite("catalog-profile")
    bindings.preampEnabled.wrappedValue = false
    #expect(source.events == ["favorite:catalog-profile:true", "preamp:false"])
    #expect(source.snapshot.preampEnabled)
  }

  @Test("Explicit import retains the originating device and user-selected file URL")
  func profileImportRetainsOrigin() {
    let source = MixerProfileTestSource()
    let bindings = MixerProfileBindings(deviceUID: "headphones-b", interface: source.interface)
    let url = URL(fileURLWithPath: "/temporary-unit-fixture/ParametricEQ.txt")
    bindings.importFile(url)
    #expect(source.lastDeviceUID == "headphones-b")
    #expect(source.lastImportURL == url)
    #expect(source.lastImportName == "ParametricEQ")
  }

  @Test("The actual profile component renders cache and catalog failures without external effects")
  func profilePaneRendersWithoutEffects() {
    _ = NSApplication.shared
    let source = MixerProfileTestSource()
    source.snapshot.catalogState = .failed("Catalog download failed.")
    source.snapshot.selection = AutoEQSelection(profileID: "offline-profile", isEnabled: false)
    source.snapshot.isMissing = true
    let host = NSHostingView(
      rootView: MixerAutoEQPanel(
        deviceUID: "headphones-a", deviceName: "Headphones", interface: source.interface))
    host.setFrameSize(NSSize(width: 380, height: 520))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 380)
    #expect(host.fittingSize.height > 0)
    #expect(source.events.isEmpty)
  }

  @Test("An unknown capture notice renders without asking for permission")
  func captureNoticeDoesNotRequestPermission() {
    _ = NSApplication.shared
    let source = MixerTestSource()
    source.snapshot.captureNotice = MixerCaptureNotice(
      message: "System audio permission has not been determined.", action: .requestPermission)
    let host = NSHostingView(
      rootView: MixerView(
        read: { source.snapshot }, actions: source.actions,
        profiles: source.profileSource.interface,
        quit: { source.events.append("quit") }
      ))
    host.setFrameSize(NSSize(width: 510, height: 560))
    host.layoutSubtreeIfNeeded()
    #expect(source.events.isEmpty)
    #expect(source.profileSource.events.isEmpty)
  }

  @Test("The real offscreen mixer uses popup density without invoking any action")
  func mixerRendersWithoutEffects() {
    _ = NSApplication.shared
    let source = MixerTestSource()
    source.snapshot.settings.popupSize = .compact
    let host = NSHostingView(
      rootView: MixerView(
        read: { source.snapshot }, actions: source.actions,
        profiles: source.profileSource.interface,
        quit: { source.events.append("quit") }
      ))
    host.setFrameSize(NSSize(width: 470, height: 500))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 470)
    #expect(host.fittingSize.height > 0)
    #expect(source.events.isEmpty)
  }
}

@MainActor
@Observable
final class MixerTestSource {
  var snapshot: MixerSnapshot
  let profileSource = MixerProfileTestSource()
  var events: [String] = []
  var lastAppID: String?
  var lastDeviceUID: String?
  var lastDeviceScope: MixerDeviceScope?
  var lastGain: Float?
  var lastBool: Bool?
  var lastBoost: BoostLevel?
  var lastEQ: EQSettings?
  var lastMode: DeviceSelectionMode?
  var lastUIDs: Set<String>?

  init() {
    let output = AudioDevice(
      id: 101, uid: "output-uid", name: "Output", icon: nil, supportsAutoEQ: true)
    let input = AudioDevice(
      id: 102, uid: "input-uid", name: "Input", icon: nil, supportsAutoEQ: false)
    snapshot = MixerSnapshot(
      apps: [
        MixerAppPresentation(
          id: "com.example.player", name: "Player", icon: nil, isActive: false,
          gain: 0.25, isMuted: false, boost: .x1, selectionMode: .single,
          isFollowingDefault: true, selectedDeviceUIDs: [], eqSettings: .flat,
          isPinned: true, isIgnored: false, routeStatus: nil
        )
      ],
      outputDevices: [
        MixerDevicePresentation(
          device: output, transport: .usb, isDefault: true, volume: 0.25, isMuted: false,
          backend: .software, automaticBackend: .software, isHidden: false,
          iconOverride: nil, volumeOverride: nil, canSetVolume: true, canSetMute: true, error: nil
        )
      ],
      inputDevices: [
        MixerDevicePresentation(
          device: input, transport: .usb, isDefault: true, volume: 0.25, isMuted: false,
          backend: .hardware, automaticBackend: .hardware, isHidden: false,
          iconOverride: nil, volumeOverride: nil, canSetVolume: true, canSetMute: true, error: nil
        )
      ], settings: .init(), userPresets: [], error: nil, backend: testDeviceSettings(),
      captureNotice: nil
    )
  }

  var bindings: MixerBindings { MixerBindings(read: { self.snapshot }, actions: actions) }

  var actions: MixerActions {
    MixerActions(
      app: MixerAppActions(
        setVolume: {
          self.lastAppID = $0
          self.lastGain = $1
          self.events.append("app-volume")
        },
        setMute: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("app-mute")
        },
        setBoost: {
          self.lastAppID = $0
          self.lastBoost = $1
          self.events.append("app-boost")
        },
        followDefault: {
          self.lastAppID = $0
          self.events.append("follow-default")
        },
        setRoute: {
          self.lastAppID = $0
          self.lastMode = $1
          self.lastUIDs = $2
          self.events.append("route")
        },
        setPinned: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("pin")
        },
        setIgnored: {
          self.lastAppID = $0
          self.lastBool = $1
          self.events.append("ignore")
        },
        setEQ: {
          self.lastAppID = $0
          self.lastEQ = $1
          self.events.append("eq")
        },
        stepVolume: {
          self.lastAppID = $0
          self.events.append("app-step:\($1):\($2)")
        },
        createPreset: { self.events.append("create-preset:\($0):\($1.bandGains.count)") },
        renamePreset: { self.events.append("rename-preset:\($0):\($1)") },
        deletePreset: { self.events.append("delete-preset:\($0)") },
        activate: {
          self.lastAppID = $0
          self.events.append("activate")
        }
      ),
      device: MixerDeviceActions(
        setDefault: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.events.append("default")
        },
        setVolume: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.lastGain = $2
          self.events.append("device-volume")
        },
        setMute: {
          self.lastDeviceScope = $0
          self.lastDeviceUID = $1
          self.lastBool = $2
          self.events.append("device-mute")
        },
        setHidden: { self.events.append("hidden:\($0):\($1):\($2)") },
        setPriority: { self.events.append("priority:\($0):\($1.joined(separator: ","))") },
        setIcon: { self.events.append("icon:\($0):\($1 ?? "automatic")") },
        setVolumeOverride: { self.events.append("override:\($0):\(String(describing: $1))") },
        stepVolume: { self.events.append("device-step:\($0):\($1):\($2):\($3)") }
      ),
      openSettings: { self.events.append("settings") }, close: { self.events.append("close") },
      backend: recordingDeviceSettingsActions { self.events.append($0) },
      requestCapturePermission: { self.events.append("capture-request") },
      openCaptureSettings: { self.events.append("capture-settings") }
    )
  }
}

@MainActor
@Observable
final class MixerProfileTestSource {
  var snapshot = MixerProfilePresentation(
    catalogState: .ready, selection: nil, profileName: nil, isMissing: false,
    isResolving: false, selectionError: nil, favoriteIDs: [], preampEnabled: true)
  var events: [String] = []
  var lastDeviceUID: String?
  var lastSelection: AutoEQSelection?
  var lastQuery: String?
  var lastFavoritesOnly: Bool?
  var lastImportURL: URL?
  var lastImportName: String?

  var interface: MixerProfileInterface {
    MixerProfileInterface(
      read: { _ in self.snapshot },
      search: {
        self.lastQuery = $0
        self.lastFavoritesOnly = $1
        return MixerProfileSearchResult(
          entries: [
            MixerProfileChoice(id: "catalog-profile", name: "Headphones", detail: "Measured")
          ],
          totalCount: 1)
      },
      importProfile: {
        self.lastDeviceUID = $0
        self.lastImportURL = $1
        self.lastImportName = $2
        self.events.append("import")
      },
      select: {
        self.lastDeviceUID = $0
        self.lastSelection = $1
        self.events.append("select")
      },
      setFavorite: { self.events.append("favorite:\($0):\($1)") },
      setPreampEnabled: { self.events.append("preamp:\($0)") })
  }
}
