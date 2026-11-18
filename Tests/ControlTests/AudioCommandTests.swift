import FineTuneControl
import FineTuneDomain
import Testing

@Suite("Control: Synchronous AudioCommand semantics")
@MainActor
struct AudioCommandTests {
  private let active = "com.unit.active"
  private let inactive = "com.unit.inactive"
  private let eq = EQSettings(bandGains: [2, -3, 1], isEnabled: true)

  private func makeController(
    store: InMemoryControlSettingsStore = InMemoryControlSettingsStore(),
    deviceCommand: (@MainActor (AudioCommand) throws -> Void)? = nil
  ) -> AudioController {
    AudioController(
      settings: store, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved }, deviceCommand: deviceCommand)
  }

  private func observeActive(_ controller: AudioController) {
    controller.observeOutputs(
      ["A", "B"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 1, isMuted: false)
      }, defaultUID: "A")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: active, processID: 101, processRevision: 1,
        displayName: "Active", bundleID: active)
    ])
  }

  @Test("Inactive commands persist wishes while only UI editGain clears mute")
  func inactiveCommandsAndMuteSemantics() {
    let store = InMemoryControlSettingsStore()
    let controller = makeController(store: store)

    controller.perform(.setMuted(identifier: inactive, muted: true))
    controller.perform(.setGain(identifier: inactive, gain: 0.4))
    #expect(store.getVolume(for: inactive) == 0.4)
    #expect(store.getMute(for: inactive) == true)

    controller.perform(.editGain(identifier: inactive, gain: 0))
    #expect(store.getVolume(for: inactive) == 0)
    #expect(store.getMute(for: inactive) == false)

    controller.perform(.setBoost(identifier: inactive, boost: .x3))
    controller.perform(.setEQ(identifier: inactive, settings: eq))
    controller.perform(.setRoute(identifier: inactive, mode: .multi, uids: ["A", "B"]))
    controller.perform(.stepSlider(identifier: inactive, delta: 0.1))
    controller.perform(.setOutputDevice(identifier: inactive, uid: "unavailable"))
    #expect(store.getVolume(for: inactive) == 0)
    #expect(store.getDeviceRouting(for: inactive) != "unavailable")

    controller.perform(.resetGainAndMute(identifier: inactive))
    #expect(store.getVolume(for: inactive) == 1)
    #expect(store.getMute(for: inactive) == false)
    #expect(store.getBoost(for: inactive) == .x3)
    #expect(store.getEQSettings(for: inactive) == eq)
    #expect(store.getDeviceSelectionMode(for: inactive) == .multi)
    #expect(store.getSelectedDeviceUIDs(for: inactive) == ["A", "B"])
  }

  @Test("Consecutive settings updates preserve earlier fields and capture wish")
  func consecutiveSettingsSnapshots() {
    let store = InMemoryControlSettingsStore()
    let controller = makeController(store: store)
    #expect(!store.appSettings.explicitUserCaptureEnabled)

    controller.perform(.requestCaptureStart)
    #expect(store.appSettings.explicitUserCaptureEnabled)

    var first = store.appSettings
    first.setUnifiedLoudnessEnabled(true)
    controller.perform(.updateAppSettings(first))
    #expect(store.appSettings.loudnessCompensationEnabled)
    #expect(store.appSettings.loudnessEqualizationEnabled)

    var second = store.appSettings
    second.defaultNewAppVolume = 0.2
    controller.perform(.updateAppSettings(second))
    #expect(store.appSettings.loudnessCompensationEnabled)
    #expect(store.appSettings.loudnessEqualizationEnabled)
    #expect(store.appSettings.defaultNewAppVolume == 0.2)
    #expect(store.appSettings.explicitUserCaptureEnabled)

    controller.perform(.stopCapture)
    #expect(!store.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Shift stepVolume doubles configured slider step and unmutes upward, including pinned rows")
  func popupShiftDoublesConfiguredStep() {
    let store = InMemoryControlSettingsStore()
    store.setVolume(for: "unit.pinned", to: 0.25)
    store.setMute(for: "unit.pinned", to: true)
    let controller = makeController(store: store)

    controller.perform(.stepVolume(identifier: "unit.pinned", isUp: true, shift: true))
    #expect(store.getVolume(for: "unit.pinned") == 0.390625)
    #expect(store.getMute(for: "unit.pinned") == false)
  }

  @Test("stepSlider and setOutputDevice act only on active apps and preserve independent fields")
  func activeOnlyStepSliderAndSetOutputDevice() {
    let store = InMemoryControlSettingsStore()
    let controller = makeController(store: store)
    observeActive(controller)

    controller.perform(.setGain(identifier: active, gain: 0.25))
    controller.perform(.setMuted(identifier: active, muted: true))
    controller.perform(.setGain(identifier: inactive, gain: 0.16))
    controller.perform(.setMuted(identifier: inactive, muted: true))
    controller.perform(.setRoute(identifier: inactive, mode: .multi, uids: ["saved"]))

    controller.perform(.stepSlider(identifier: active, delta: 0.05))
    controller.perform(.stepSlider(identifier: inactive, delta: 0.05))
    controller.perform(.setOutputDevice(identifier: active, uid: "B"))
    controller.perform(.setOutputDevice(identifier: inactive, uid: "B"))

    let stepped = store.getVolume(for: active) ?? -1
    #expect(abs(stepped - 0.3025) < 0.000_001)
    #expect(store.getMute(for: active) == true)
    #expect(store.getDeviceSelectionMode(for: active) == .single)
    #expect(store.getSelectedDeviceUIDs(for: active) == ["B"])

    #expect(store.getVolume(for: inactive) == 0.16)
    #expect(store.getMute(for: inactive) == true)
    #expect(store.getDeviceSelectionMode(for: inactive) == .multi)
    #expect(store.getSelectedDeviceUIDs(for: inactive) == ["saved"])
    #expect(!store.appSettings.explicitUserCaptureEnabled)

    controller.perform(.stepSlider(identifier: active, delta: .nan))
    #expect(controller.commandFailure?.kind == .unsupported)
  }

  @Test("Targetless reset touches only active apps; explicit reset preserves boost, EQ, and route")
  func resetGainAndMuteScope() {
    let store = InMemoryControlSettingsStore()
    let controller = makeController(store: store)
    observeActive(controller)

    for id in [active, inactive] {
      controller.perform(.setGain(identifier: id, gain: 0.2))
      controller.perform(.setMuted(identifier: id, muted: true))
      controller.perform(.setBoost(identifier: id, boost: .x3))
      controller.perform(.setEQ(identifier: id, settings: eq))
      controller.perform(.setRoute(identifier: id, mode: .multi, uids: ["A", "B"]))
    }

    controller.perform(.resetGainAndMute(identifier: nil))
    #expect(controller.gain(for: active) == 1 && !controller.isMuted(for: active))
    #expect(store.getVolume(for: inactive) == 0.2 && store.getMute(for: inactive) == true)

    controller.perform(.resetGainAndMute(identifier: inactive))
    for id in [active, inactive] {
      #expect(store.getVolume(for: id) == 1)
      #expect(store.getMute(for: id) == false)
      #expect(store.getBoost(for: id) == .x3)
      #expect(store.getEQSettings(for: id) == eq)
      #expect(store.getDeviceSelectionMode(for: id) == .multi)
      #expect(store.getSelectedDeviceUIDs(for: id) == ["A", "B"])
    }
    #expect(!store.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Invalid app gains set commandFailure without mutating saved wishes")
  func invalidAppGainRejected() {
    let store = InMemoryControlSettingsStore()
    let controller = makeController(store: store)
    controller.perform(.setGain(identifier: inactive, gain: 0.5))

    for bad in [Float.nan, -0.01, 1.01, .infinity] {
      controller.perform(.setGain(identifier: inactive, gain: bad))
      #expect(controller.commandFailure?.kind == .unsupported)
      #expect(store.getVolume(for: inactive) == 0.5)
    }

    controller.perform(.editGain(identifier: "", gain: 0.3))
    #expect(controller.commandFailure?.kind == .unsupported)
  }

  @Test("Device commands forward cleanly or surface unavailable backend errors")
  func deviceCommandForwardingAndUnavailableError() {
    let unavailable = makeController(deviceCommand: nil)
    unavailable.perform(.setDeviceGain(scope: .output, uid: "speaker", gain: 0.5))
    #expect(unavailable.commandFailure?.kind == .unavailable)

    var forwarded: [AudioCommand] = []
    let wired = makeController(deviceCommand: { forwarded.append($0) })
    let commands: [AudioCommand] = [
      .setDefaultDevice(scope: .input, uid: "mic"),
      .setDeviceGain(scope: .output, uid: "speaker", gain: 0.7),
      .setRawDeviceGain(scope: .output, uid: "speaker", gain: 0.6),
      .setDeviceMuted(scope: .input, uid: "mic", muted: true),
      .stepDeviceVolume(scope: .output, uid: "speaker", isUp: false, shift: true),
      .setDeviceHidden(scope: .output, uid: "speaker", hidden: true),
      .setDevicePriority(scope: .output, connectedUIDs: ["speaker", "other"]),
      .setDeviceIcon(uid: "speaker", symbol: "hifispeaker"),
      .setDeviceVolumeOverride(uid: "speaker", tier: .software),
    ]
    for command in commands { wired.perform(command) }
    #expect(wired.commandFailure == nil)
    #expect(forwarded == commands)
  }
}
