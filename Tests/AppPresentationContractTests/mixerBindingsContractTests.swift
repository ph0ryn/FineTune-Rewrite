// No-render contracts for mixer bindings, device row capabilities, EQ, and percentage bounds.
import FineTuneDomain
import Foundation
import Testing

@testable import FineTune

@Suite("Presentation contract: mixer bindings and device row actions")
@MainActor
struct MixerBindingsContractTests {
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

  @Test("Device default-selection callback forwards the scoped device identity")
  func deviceRowSetDefaultForwardsScopeAndUID() {
    let source = MixerTestSource()
    for (scope, device) in [
      (MixerDeviceScope.output, source.snapshot.outputDevices[0]),
      (.input, source.snapshot.inputDevices[0]),
    ] {
      source.events.removeAll()
      let row = source.bindings.deviceRow(device, scope: scope)
      row.onSetDefault()
      #expect(source.events == ["default"])
      #expect(source.lastDeviceScope == scope)
      #expect(source.lastDeviceUID == device.id)
    }
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

  @Test(
    "Typed device percentages parse, clamp and keep the scoped volume curve",
    arguments: [false, true])
  func editableDevicePercentageClampAndCurve(isInput: Bool) throws {
    let source = MixerTestSource()
    let scope: MixerDeviceScope = isInput ? .input : .output
    let device = isInput ? source.snapshot.inputDevices[0] : source.snapshot.outputDevices[0]
    let slider = try #require(source.bindings.deviceRow(device, scope: scope).slider)
    let format = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
    #expect(format.format(slider.wrappedValue) == (isInput ? "25%" : "50%"))
    let percentage = VolumePercentageField(
      value: slider, range: 0...100, label: "\(device.device.name) volume percentage")
    percentage.boundedValue.wrappedValue = try format.parseStrategy.parse("60%")
    #expect(source.events == ["device-volume"])
    #expect(source.lastDeviceScope == scope && source.lastDeviceUID == device.id)
    let gain = try #require(source.lastGain)
    #expect(abs(gain - (isInput ? 0.6 : 0.36)) < 0.000_001)
    percentage.boundedValue.wrappedValue = 1.4
    #expect(source.lastGain == 1)
    percentage.boundedValue.wrappedValue = -0.2
    #expect(source.lastGain == 0)
  }
}
