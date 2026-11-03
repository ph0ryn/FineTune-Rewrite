// FineTuneTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialState)
        case updateEQSettings(EQSettings)
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case invalidate
    }

    let app: AudioApp
    private(set) var events: [Event] = []

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    // Extra failure injection for the new route-ownership boundary tests below.
    var activationError: (any Error)?

    func activate(initial: TapInitialState) throws {
        events.append(.activate(initial))
        if let activationError { throw activationError }
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir, launchAtLoginService: TestLaunchAtLoginService())

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // The new composition receives an observed authorization value. This fixture
    // explicitly authorizes its recording double; it never preflights private TCC
    // SPI, requests capture, or changes the production default of unknown.
    let permission = AudioCaptureAuthorization()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileCache(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        app: app,
        device: device,
        lastTap: { box.last }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfile?.id == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfile?.id == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfile?.id == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfile?.id == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ remains unavailable without changing the enabled selection")
    func cacheMissPreservesUnavailableSelection() throws {
        // Original ID: cacheMissTriggersPostActivateNilSet. The old internal setter
        // established a nil correction after activation. The new boundary prepares
        // that same nil state before activation and reports why the selected profile
        // cannot yet be used, without pretending to fetch/apply it.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // New boundary: a complete nil profile was prepared before activation, so no
        // redundant post-activation nil mutation is required to establish this state.
        let initial = try #require(capturedInitial(fix))
        #expect(initial.autoEQProfile?.id == nil)
        let snapshot = try #require(fix.engine.routeSnapshots[fix.app.id])
        #expect(snapshot.initialState?.autoEQProfile == nil)
        #expect(snapshot.autoEQ == .unavailable(profileID: "missing-id"))
        #expect(snapshot.isActive)
        #expect(snapshot.failure == nil)
        let desired = try #require(fix.settings.getAutoEQSelection(for: fix.device.uid))
        #expect(desired.profileID == "missing-id")
        #expect(desired.isEnabled)
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> TapInitialState? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

// MARK: - Mock contract

@Suite("Audio route — required Control port contract")
@MainActor
struct AudioRoutePortContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Empty Control state prepares unity volume, independent mute, flat EQ and no correction")
    func controlInitialStateDefaults() {
        // Original ID: defaultsMatchProductionController. A test-double's old internal
        // field defaults are not a product contract; these are actual Control values.
        let volume = VolumeState()
        let initial = TapInitialState()
        #expect(volume.getVolume(for: 1) == 1)
        #expect(volume.getMute(for: 1) == false)
        #expect(volume.getBoost(for: 1) == .x1)
        #expect(initial.eqSettings == .flat)
        #expect(initial.autoEQProfile == nil)
        #expect(initial.autoEQPreampEnabled == false)
        #expect(initial.loudnessVolume == 1)
        #expect(initial.loudnessCompensationEnabled == false)
        #expect(initial.loudnessEqualizerSettings.enabled == false)
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfile?.id == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.flat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}

// Rewrite-specific contracts: observing success must not be confused with saving a request.
@Suite("AudioEngine — explicit runtime and authorization failures")
@MainActor
struct AudioEngineRouteBoundaryTests {
    private enum ExpectedFailure: Error { case activation }

    @Test("Unknown authorization does not construct a runtime or discard the requested output")
    func unknownAuthorizationPreservesRequest() throws {
        let setup = makeBoundarySetup()
        var factoryCalls = 0
        let engine = AudioEngine(
            settingsManager: setup.settings,
            deviceProvider: setup.devices,
            deviceVolumeMonitor: setup.volume,
            tapFactory: { app, uids, _ in
                factoryCalls += 1
                return RecordingProcessTapController(app: app, deviceUIDs: uids)
            },
            startMonitorsAutomatically: false
        )

        engine.setDevice(for: setup.app, deviceUID: setup.device.uid)

        #expect(factoryCalls == 0)
        let snapshot = try #require(engine.routeSnapshots[setup.app.id])
        #expect(snapshot.isActive == false)
        #expect(snapshot.failure?.contains("authorizationUnknown") == true)
        #expect(setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    }

    @Test("An unavailable live adapter reports failure instead of pretending that capture started")
    func unavailableRuntimePreservesRequest() throws {
        let setup = makeBoundarySetup()
        let engine = AudioEngine(
            permission: AudioCaptureAuthorization(status: .authorized),
            settingsManager: setup.settings,
            deviceProvider: setup.devices,
            deviceVolumeMonitor: setup.volume,
            startMonitorsAutomatically: false
        )

        engine.setDevice(for: setup.app, deviceUID: setup.device.uid)

        let snapshot = try #require(engine.routeSnapshots[setup.app.id])
        #expect(snapshot.isActive == false)
        #expect(snapshot.failure?.contains("liveRuntimeUnavailable") == true)
        #expect(setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    }

    @Test("A failed replacement disposes only the candidate and preserves the active route")
    func failedActivationKeepsOldRoute() throws {
        let setup = makeBoundarySetup()
        let other = AudioDevice(id: 100, uid: "uid-failed", name: "Unavailable Output", icon: nil, supportsAutoEQ: true)
        setup.devices.addOutputDevice(other)
        var created: [RecordingProcessTapController] = []
        let engine = AudioEngine(
            permission: AudioCaptureAuthorization(status: .authorized),
            settingsManager: setup.settings,
            deviceProvider: setup.devices,
            deviceVolumeMonitor: setup.volume,
            tapFactory: { app, uids, _ in
                let route = RecordingProcessTapController(app: app, deviceUIDs: uids)
                if !created.isEmpty { route.activationError = ExpectedFailure.activation }
                created.append(route)
                return route
            },
            startMonitorsAutomatically: false
        )
        engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
        engine.setDevice(for: setup.app, deviceUID: other.uid)

        #expect(created.count == 2)
        let snapshot = try #require(engine.routeSnapshots[setup.app.id])
        #expect(snapshot.isActive)
        #expect(snapshot.deviceUIDs == [setup.device.uid])
        #expect(snapshot.failure?.contains("activation") == true)
        #expect(setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == other.uid)
        #expect(!created[0].events.contains { if case .invalidate = $0 { return true }; return false })
        #expect(created[1].events.contains { if case .invalidate = $0 { return true }; return false })
    }

    @Test("A vanished process releases its route but keeps the saved app preferences")
    func vanishedProcessReleasesRoute() throws {
        let setup = makeBoundarySetup()
        let processes = StubProcessMonitor()
        processes.activeApps = [setup.app]
        var created: RecordingProcessTapController?
        let engine = AudioEngine(
            permission: AudioCaptureAuthorization(status: .authorized),
            settingsManager: setup.settings,
            deviceProvider: setup.devices,
            processMonitor: processes,
            deviceVolumeMonitor: setup.volume,
            tapFactory: { app, uids, _ in
                let route = RecordingProcessTapController(app: app, deviceUIDs: uids)
                created = route
                return route
            },
            startMonitorsAutomatically: false
        )
        engine.setVolume(for: setup.app, to: 0.25)
        engine.setDevice(for: setup.app, deviceUID: setup.device.uid)
        let route = try #require(created)

        processes.activeApps = []
        processes.onAppsChanged?([])

        #expect(engine.apps.isEmpty)
        #expect(engine.routeSnapshots[setup.app.id] == nil)
        #expect(route.events.contains { if case .invalidate = $0 { return true }; return false })
        #expect(engine.volumeState.getVolume(for: setup.app.id) == setup.settings.appSettings.defaultNewAppVolume)
        #expect(setup.settings.getVolume(for: setup.app.persistenceIdentifier) == 0.25)
        #expect(setup.settings.getDeviceRouting(for: setup.app.persistenceIdentifier) == setup.device.uid)
    }

    @Test("The actual profile cache retains inserted values and does not invent absent profiles", arguments: [false, true])
    func profileCacheRetainsValues(loadAtInitialization: Bool) {
        let profile = AutoEQProfile(
            id: "cached", name: "Cached profile", source: .imported, preampDB: -3,
            filters: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 2, q: 0.7)]
        )
        let cache = AutoEQProfileCache(profiles: loadAtInitialization ? [profile] : [])
        if !loadAtInitialization { cache.store(profile) }
        #expect(cache.profile(for: "cached") == profile)
        #expect(cache.profile(for: "missing") == nil)
    }

    private func makeBoundarySetup() -> (
        settings: SettingsManager, devices: MockAudioDeviceMonitor, volume: MockDeviceVolumeProviding,
        app: AudioApp, device: AudioDevice
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory, launchAtLoginService: TestLaunchAtLoginService())
        let devices = MockAudioDeviceMonitor()
        let device = AudioDevice(id: 99, uid: "uid-existing", name: "Existing Output", icon: nil, supportsAutoEQ: true)
        devices.addOutputDevice(device)
        let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        let app = AudioApp(id: 12345, processObjectIDs: [], name: "RouteTest", icon: NSImage(), bundleID: "com.test.route")
        return (settings, devices, volume, app, device)
    }
}
