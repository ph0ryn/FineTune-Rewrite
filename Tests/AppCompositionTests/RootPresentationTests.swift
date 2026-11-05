import AppKit
import AudioToolbox
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("Actual Root presentation without live services")
@MainActor
struct RootPresentationTests {
  @Test("Construction and repeated snapshots only read the actual passive owners")
  func constructionAndSnapshotsArePassive() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let mixer = presentation.mixerSnapshot()
    let settings = presentation.settingsSnapshot()
    presentation.invalidate()
    #expect(presentation.mixerSnapshot().apps.isEmpty)
    #expect(mixer.outputDevices.map(\.id) == ["speaker"])
    #expect(mixer.inputDevices.map(\.id) == ["mic"])
    #expect(
      mixer.outputDevices.allSatisfy {
        $0.volume == nil && $0.isMuted == nil && !$0.canSetVolume && !$0.canSetMute
          && $0.automaticBackend == nil
      })
    #expect(!settings.isAccessibilityTrusted && !settings.isMediaKeyOffline)
    #expect(mixer.error == nil && settings.error == nil)
    #expect(mixer.captureNotice?.action == .requestPermission)
    let missingDescription = fixture.presentation(hasUsageDescription: false).mixerSnapshot()
    #expect(missingDescription.captureNotice?.action == nil)
    #expect(missingDescription.captureNotice?.message.contains("unavailable") == true)
    #expect(fixture.graph.settings === fixture.settings)
    #expect(fixture.graph.bindings.controller === fixture.graph.controller)
    #expect(fixture.graph.devices === fixture.devices && fixture.graph.volumes === fixture.output)
    await fixture.expectPassivePorts()
  }

  @Test("Snapshots read new real settings and stable live plus saved app identities without copies")
  func snapshotsReadThroughTheSameOwners() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    fixture.processes.apps = [
      fixture.app(id: 101, uid: "unit.live-b", name: "Shared"),
      fixture.app(id: 102, uid: "unit.live-a", name: "Shared"),
      fixture.app(id: 103, uid: "unit.saved", name: "Saved player"),
      fixture.app(id: 104, uid: "unit.ignored", name: "Ignored player"),
    ]
    // Real saved metadata comes from a previously observed app, not an invented inactive name.
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.perform(.setPinned(identifier: "unit.live-a", pinned: true))
    controller.perform(.setPinned(identifier: "unit.saved", pinned: true))
    #expect(controller.commandFailure == nil)
    controller.perform(.setIgnored(identifier: "unit.live-b", ignored: true))
    controller.perform(.setIgnored(identifier: "unit.ignored", ignored: true))
    #expect(controller.commandFailure == nil)
    controller.perform(.setGain(identifier: "unit.live-a", gain: 0.5))
    controller.perform(.setMuted(identifier: "unit.live-a", muted: true))
    controller.perform(.setGain(identifier: "unit.saved", gain: 0.25))
    controller.perform(
      .setRoute(identifier: "unit.saved", mode: .multi, uids: ["speaker", "gone"]))
    fixture.processes.apps.removeLast(2)
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()
    let halBeforeSnapshot = fixture.hal.calls
    let preset = fixture.settings.createUserPreset(name: "Saved curve", settings: .flat)
    var wishes = fixture.settings.appSettings
    wishes.explicitUserCaptureEnabled = true
    fixture.settings.updateAppSettings(wishes)
    fixture.trust.isTrusted = true
    fixture.mediaKeys.isOffline = true
    presentation.invalidate()

    let snapshot = presentation.mixerSnapshot()
    #expect(snapshot.apps.count == 4)
    #expect(
      Set(snapshot.apps.map(\.id)) == ["unit.live-a", "unit.live-b", "unit.saved", "unit.ignored"])
    #expect(snapshot.apps.filter(\.isActive).map(\.id) == ["unit.live-a", "unit.live-b"])
    let live = try #require(snapshot.apps.first { $0.id == "unit.live-a" })
    let saved = try #require(snapshot.apps.first { $0.id == "unit.saved" })
    #expect(live.gain == 0.5 && live.isMuted && live.isPinned)
    #expect(!saved.isActive && saved.isPinned && saved.gain == 0.25)
    #expect(saved.selectionMode == .multi && !saved.isFollowingDefault)
    #expect(saved.selectedDeviceUIDs == ["speaker", "gone"])
    #expect(snapshot.apps.first { $0.id == "unit.ignored" }?.isIgnored == true)
    #expect(snapshot.apps.filter { $0.id == "unit.live-b" }.count == 1)
    #expect(snapshot.userPresets.map(\.id) == [preset.id])
    #expect(snapshot.settings.explicitUserCaptureEnabled)
    let settings = presentation.settingsSnapshot()
    #expect(settings.settings.explicitUserCaptureEnabled)
    #expect(settings.isAccessibilityTrusted && settings.isMediaKeyOffline)
    // A saved wish and cached AX status are not a newly granted capture intent.
    #expect(controller.captureIntent == .none)
    #expect(snapshot.captureNotice?.action == .requestPermission)
    await fixture.expectPassivePorts(halBaseline: halBeforeSnapshot)
    print(
      "RootPresentation saved-app snapshot HAL: before=\(halBeforeSnapshot), after=\(fixture.hal.calls)"
    )

    fixture.processes.apps[1] = fixture.app(id: 202, uid: "unit.live-a", name: "Renamed")
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()
    let halBeforeRefresh = fixture.hal.calls
    let refreshed = presentation.mixerSnapshot()
    #expect(refreshed.apps.count == 4)
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.name == "Renamed")
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.gain == 0.5)
    #expect(refreshed.apps.first { $0.id == "unit.live-a" }?.isMuted == true)
    await fixture.expectPassivePorts(halBaseline: halBeforeRefresh)
    print(
      "RootPresentation rebound snapshot HAL: before=\(halBeforeRefresh), after=\(fixture.hal.calls)"
    )
  }

  @Test(
    "Inactive saved rows retain cached installed artwork without claiming activity or reading OS metadata"
  )
  func savedRowsUseCachedArtwork() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let savedIcon = NSImage(size: NSSize(width: 2, height: 2))
    let ignoredIcon = NSImage(size: NSSize(width: 3, height: 3))
    fixture.inactiveIcons = ["unit.saved": savedIcon, "unit.ignored": ignoredIcon]
    fixture.processes.apps = [
      fixture.app(id: 101, uid: "unit.saved", name: "Saved"),
      fixture.app(id: 102, uid: "unit.ignored", name: "Ignored"),
      fixture.app(id: 103, uid: "unit.missing", name: "Missing"),
    ]
    fixture.graph.engine.ingestObservations()
    fixture.graph.controller.perform(.setPinned(identifier: "unit.saved", pinned: true))
    fixture.graph.controller.perform(.setIgnored(identifier: "unit.ignored", ignored: true))
    fixture.graph.controller.perform(.setPinned(identifier: "unit.missing", pinned: true))
    fixture.processes.apps = []
    fixture.processes.revision += 1
    fixture.graph.engine.ingestObservations()
    let halBaseline = fixture.hal.calls
    let presentation = fixture.presentation()
    for _ in 0..<2 {
      let rows = presentation.mixerSnapshot().apps
      #expect(rows.count == 3 && rows.allSatisfy { !$0.isActive && $0.peakLevel == nil })
      #expect(rows.first { $0.id == "unit.saved" }?.icon === savedIcon)
      #expect(rows.first { $0.id == "unit.ignored" }?.icon === ignoredIcon)
      #expect(rows.first { $0.id == "unit.missing" }?.icon == nil)
    }
    presentation.applicationActivationFailure = "Unit reopen failed"
    #expect(presentation.mixerSnapshot().error == "Unit reopen failed")
    #expect(presentation.settingsSnapshot().error == "Unit reopen failed")
    presentation.applicationActivationFailure = nil
    #expect(presentation.mixerSnapshot().error == nil)
    await fixture.expectPassivePorts(halBaseline: halBaseline)
  }

  @Test(
    "Mixer reads only the current healthy routes' actual cached peak and clears missing samples")
  func currentRoutePeaksReadThroughWithoutNativeIO() async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let presentation = fixture.presentation()
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    let controller = fixture.graph.controller
    controller.observeOutputs(
      ["speaker", "headphones"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      }, defaultUID: "speaker")
    controller.perform(
      .setRoute(identifier: "unit.player", mode: .multi, uids: ["speaker", "headphones"]))
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let speaker = try #require(runtime.handle("speaker"))
    let headphones = try #require(runtime.handle("headphones"))
    #expect(presentation.mixerSnapshot().apps.first?.routeStatus == nil)
    speaker.onObservation?(
      AudioRouteObservation(key: speaker.key, phase: .firstApplied, peakLevel: 0.25))
    headphones.onObservation?(
      AudioRouteObservation(key: headphones.key, phase: .firstApplied, peakLevel: 0.75))
    let halBaseline = fixture.hal.calls
    #expect(controller.routeObservations[speaker.key]?.peakLevel == 0.25)
    #expect(controller.routeObservations[headphones.key]?.peakLevel == 0.75)
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0.75)
    #expect(presentation.mixerSnapshot().apps.first?.routeStatus == nil)
    headphones.onObservation?(
      AudioRouteObservation(key: headphones.key, phase: .firstApplied, peakLevel: nil))
    #expect(controller.routeObservations[headphones.key]?.peakLevel == nil)
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0.25)
    speaker.onObservation?(
      AudioRouteObservation(key: speaker.key, phase: .firstApplied, peakLevel: 0))
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0)

    fixture.processes.revision = 2
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: "unit.player", processID: 101, processRevision: 2,
        displayName: "Player", bundleID: "unit.player")
    ])
    await controller.waitForCurrentWork()
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    speaker.onObservation?(
      AudioRouteObservation(key: speaker.key, phase: .firstApplied, peakLevel: 0.95))
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    let current = try #require(runtime.handle("speaker"))
    #expect(current.key.generation > speaker.key.generation)
    current.onObservation?(
      AudioRouteObservation(key: current.key, phase: .firstApplied, peakLevel: 0.5))
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == 0.5)
    #expect(presentation.mixerSnapshot().apps.first?.routeStatus == nil)
    current.onObservation?(
      AudioRouteObservation(
        key: current.key, phase: .firstApplied,
        cleanupFailure: AudioRouteFailure(stage: "unit-cleanup", message: "Cleanup is unavailable"),
        peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    #expect(
      presentation.mixerSnapshot().apps.first?.routeStatus
        == "Cleanup is unavailable (cleanup stage: unit-cleanup)")
    current.onObservation?(
      AudioRouteObservation(key: current.key, phase: .firstApplied, peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    current.onObservation?(
      AudioRouteObservation(key: current.key, phase: .retiring, peakLevel: 0.9))
    #expect(controller.routeObservations[current.key]?.peakLevel == nil)
    controller.observeApplications([], failure: "Current process observation is unavailable")
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    await controller.shutdown()
    #expect(presentation.mixerSnapshot().apps.first?.peakLevel == nil)
    await fixture.expectPassivePorts(halBaseline: halBaseline)
  }

  @Test(
    "A failed capture exposes an explicit retry without snapshot-driven attempts",
    arguments: [false, true])
  func captureFailureOffersExplicitRetry(readTapFailure: Bool) async throws {
    let failure = AudioRouteFailure(
      kind: readTapFailure ? .unsupported : .nativeFailure,
      stage: readTapFailure ? "inspectTap" : "createTap", code: -7201,
      message: "Capture did not start; the native result did not establish authorization.")
    let fixture = try RootPresentationFixture(captureFailure: failure)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.live", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      ], defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(controller.routeFailure == failure)
    #expect(!controller.knownPermissionDenied)
    #expect(fixture.effects.nativeResolutions == 1)
    let presentation = fixture.presentation()
    let halBaseline = fixture.hal.calls
    for _ in 0..<3 {
      let snapshot = presentation.mixerSnapshot()
      let expected = "\(failure.message) (stage: \(failure.stage), native code: -7201)"
      #expect(snapshot.captureNotice?.message == expected)
      #expect(snapshot.captureNotice?.action == .retryCapture)
      #expect(snapshot.error == nil)
      #expect(presentation.settingsSnapshot().error == expected)
    }
    #expect(fixture.effects.nativeResolutions == 1 && fixture.hal.calls == halBaseline)
    // This is the existing command used by the Root's explicit capture action, not a passive read.
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    #expect(fixture.effects.nativeResolutions == 2)
    #expect(!controller.knownPermissionDenied)
    #expect(await fixture.transport.calls == 0)
    await controller.shutdown()
  }

  @Test(
    "Retired late START/COMMIT cancellation history is not a current Root banner or row failure",
    arguments: RoutingDeferredOperation.allCases)
  func lateCancelledHistoryDoesNotLeakIntoRecoveredSnapshots(
    operation: RoutingDeferredOperation
  ) async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      ["speaker", "B", "C"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      }, defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    runtime.holdOperations["B"] = operation
    runtime.holdRetirement = ["B"]
    controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["B"]))
    await runtime.wait("deferred-\(operation.rawValue):B")
    let late = try #require(runtime.handle("B"))
    controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["C"]))
    await runtime.wait("retire:B")
    runtime.releaseOperation("B")
    await runtime.wait("late-cancelled:B")
    late.finishRetirement()
    await controller.waitForCurrentWork()
    let current = try #require(runtime.handle("C"))
    #expect(current.rendering && !current.retired)
    #expect(controller.activeDeviceUIDs(for: "unit.player") == ["C"])
    #expect(controller.lastFailure == nil && controller.captureRetryFailure == nil)
    #expect(controller.routeObservations[late.key]?.phase == .retired)
    #expect(controller.routeObservations[late.key]?.failure?.kind == .cancelled)
    let presentation = fixture.presentation()
    let halBaseline = fixture.hal.calls
    for _ in 0..<2 {
      let mixer = presentation.mixerSnapshot()
      let row = try #require(mixer.apps.first { $0.id == "unit.player" })
      #expect(mixer.captureNotice == nil)
      #expect(mixer.error == nil)
      #expect(presentation.settingsSnapshot().error == nil)
      #expect(row.routeStatus == nil)
    }
    await fixture.expectPassivePorts(halBaseline: halBaseline)
    await controller.shutdown()
    #expect(late.retired && current.retired && !current.rendering)
  }

  @Test(
    "A healthy multi-output commit cannot hide a retained owner's fault before explicit recovery",
    arguments: [AudioRouteFailureKind.nativeFailure, .cancelled])
  func retainedMultiOutputFailureSurvivesAnotherOutputCommit(kind: AudioRouteFailureKind)
    async throws
  {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      ["speaker", "B"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      }, defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let retained = try #require(runtime.handle("speaker"))
    #expect(retained.rendering)
    runtime.holdUpdates = ["speaker"]
    let nextUpdate = retained.updates.count + 1
    controller.perform(.setGain(identifier: "unit.player", gain: 0.5))
    await runtime.wait("update:speaker:\(nextUpdate)")
    let updating = Task { @MainActor in
      runtime.emit("draining-retained-update")
      await controller.waitForCurrentWork()
    }
    await runtime.wait("draining-retained-update")
    runtime.holdOperations["B"] = .commit
    controller.perform(.setRoute(identifier: "unit.player", mode: .multi, uids: ["speaker", "B"]))
    await runtime.wait("deferred-commit:B")
    // No delayed full-state receipt may accidentally re-latch the fault after B's commit clears it.
    runtime.releaseUpdates("speaker")
    await updating.value
    let healthy = try #require(runtime.handle("B"))
    #expect(retained.rendering && retained.retirementAttempts == 0 && healthy.commits.isEmpty)
    let failure = AudioRouteFailure(
      kind: kind, stage: "render", code: -7301, message: "Retained speaker rendering failed")
    let expected = "\(failure.message) (stage: render, native code: -7301)"
    retained.rendering = false
    retained.onObservation?(
      AudioRouteObservation(key: retained.key, phase: .failed, failure: failure))
    #expect(controller.routeFailures["unit.player"] == failure && controller.lastFailure == failure)
    runtime.releaseOperation("B")
    await controller.waitForCurrentWork()
    #expect(healthy.rendering && !healthy.retired && healthy.retirementAttempts == 0)
    #expect(!retained.rendering && !retained.retired && retained.retirementAttempts == 0)
    #expect(controller.routeObservations[retained.key]?.failure == failure)
    #expect(controller.activeDeviceUIDs(for: "unit.player") == ["B"])
    #expect(controller.captureRetryFailure == nil && runtime.requests.count == 2)
    #expect(controller.routeFailures["unit.player"] == failure)
    #expect(controller.lastFailure == failure)
    let presentation = fixture.presentation()
    let halBaseline = fixture.hal.calls
    let failedSnapshot = presentation.mixerSnapshot()
    #expect(failedSnapshot.error == expected)
    #expect(failedSnapshot.apps.first?.routeStatus == expected)
    #expect(presentation.settingsSnapshot().error == expected)
    runtime.holdArmed = ["speaker"]
    controller.perform(.setRoute(identifier: "unit.player", mode: .multi, uids: ["speaker", "B"]))
    await runtime.wait("started:speaker")
    let recovered = try #require(runtime.handle("speaker"))
    #expect(recovered !== retained && recovered.commits.isEmpty)
    #expect(controller.routeFailures["unit.player"] == failure)
    #expect(healthy.rendering && healthy.retirementAttempts == 0)
    recovered.arm()
    await controller.waitForCurrentWork()
    #expect(controller.activeDeviceUIDs(for: "unit.player") == ["speaker", "B"])
    #expect(recovered.rendering && retained.retired && runtime.requests.count == 3)
    #expect(runtime.handle("B") === healthy && healthy.rendering && healthy.retirementAttempts == 0)
    #expect(controller.routeFailures["unit.player"] == nil && controller.lastFailure == nil)
    let recoveredSnapshot = presentation.mixerSnapshot()
    #expect(recoveredSnapshot.error == nil && recoveredSnapshot.apps.first?.routeStatus == nil)
    #expect(presentation.settingsSnapshot().error == nil)
    await fixture.expectPassivePorts(halBaseline: halBaseline)
    await controller.shutdown()
    #expect(recovered.retired && healthy.retired)
  }

  @Test(
    "Native diagnostics retain the exact optional code and distinguish primary from cleanup",
    arguments: [Int32?(560_947_818), -7201, nil],
    [AudioRouteFailureKind.nativeFailure, .cancelled])
  func nativeDiagnosticsKeepStageCodeAndCleanupRole(
    code: Int32?, kind: AudioRouteFailureKind
  ) async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      ["speaker", "headphones"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      }, defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("speaker"))
    let failure = AudioRouteFailure(
      kind: kind, stage: "createAggregate", code: code,
      message: "Native audio could not complete the requested operation.")
    route.onObservation?(
      AudioRouteObservation(
        key: route.key, phase: .failed, failure: failure, cleanupFailure: failure))
    let primary: String
    let cleanup: String
    if let code {
      primary = "\(failure.message) (stage: createAggregate, native code: \(code))"
      cleanup = "\(failure.message) (cleanup stage: createAggregate, native code: \(code))"
    } else {
      primary = "\(failure.message) (stage: createAggregate)"
      cleanup = "\(failure.message) (cleanup stage: createAggregate)"
    }
    let expected = "\(primary)\n\(cleanup)"
    let presentation = fixture.presentation()
    let halBaseline = fixture.hal.calls
    let commands = fixture.effects.commands
    for _ in 0..<2 {
      let snapshot = presentation.mixerSnapshot()
      let visible = [snapshot.captureNotice?.message, snapshot.error].compactMap { $0 }
        .joined(separator: "\n")
      #expect(visible == expected)
      #expect(snapshot.apps.first?.routeStatus == expected)
      #expect(presentation.settingsSnapshot().error == expected)
      #expect(!visible.contains("OSStatus"))
      if code == nil { #expect(!visible.contains("native code")) }
    }
    #expect(fixture.effects.commands == commands)
    runtime.holdArmed = ["headphones"]
    controller.perform(.setRoute(identifier: "unit.player", mode: .single, uids: ["headphones"]))
    await runtime.wait("started:headphones")
    let candidate = try #require(runtime.handle("headphones"))
    #expect(candidate.commits.isEmpty && route.retirementAttempts == 0)
    #expect(controller.lastFailure == failure)
    let pending = presentation.mixerSnapshot()
    #expect(pending.error == expected)
    #expect(pending.apps.first?.routeStatus == expected)
    #expect(presentation.settingsSnapshot().error == expected)
    await fixture.expectPassivePorts(halBaseline: halBaseline)
    await controller.shutdown()
  }

  @Test("A failed route without details shows a meaningful warning instead of its raw phase")
  func failedRouteWithoutDetailsStillWarns() async throws {
    let runtime = RoutingProbeRuntime()
    let fixture = try RootPresentationFixture(runtime: runtime)
    defer { fixture.cleanUp() }
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.player", name: "Player")]
    fixture.graph.engine.ingestObservations()
    let controller = fixture.graph.controller
    controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      ], defaultUID: "speaker")
    controller.perform(.requestCaptureStart)
    await controller.waitForCurrentWork()
    let route = try #require(runtime.handle("speaker"))
    route.onObservation?(AudioRouteObservation(key: route.key, phase: .failed))
    let halBaseline = fixture.hal.calls
    let presentation = fixture.presentation()
    for _ in 0..<2 {
      #expect(presentation.mixerSnapshot().apps.first?.routeStatus == "Audio routing failed.")
    }
    await fixture.expectPassivePorts(halBaseline: halBaseline)
    await controller.shutdown()
  }

  @Test("The required activation action forwards exact identity without editing audio")
  func activationUsesTheRequiredPort() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    var activated: [String] = []
    let actions = fixture.graph.bindings.appActions(activate: { activated.append($0) })
    actions.activate("Com.Example.Player")
    #expect(activated == ["Com.Example.Player"])
    #expect(fixture.graph.controller.captureIntent == .none)
    #expect(fixture.graph.controller.applications.isEmpty)
    #expect(fixture.graph.controller.routeObservations.isEmpty)
    await fixture.expectPassivePorts()
  }

  @Test("Mixer presents a shared process diagnostic once and retains independent errors")
  func processDiagnosticAppearsOnce() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let processFailure = "Application metadata has an invalid or duplicate process identity."
    fixture.graph.controller.observeApplications([], failure: processFailure)
    let processOnly = presentation.mixerSnapshot()
    #expect(processOnly.captureNotice?.message == processFailure)
    #expect(processOnly.error == nil)
    #expect(presentation.settingsSnapshot().error == processFailure)

    let outputFailure = "Output role observation is unavailable."
    fixture.graph.controller.observeOutputs([], defaultUID: nil, failure: outputFailure)
    let independent = presentation.mixerSnapshot()
    #expect(independent.captureNotice?.message == processFailure)
    #expect(independent.error == outputFailure)
    #expect(
      presentation.settingsSnapshot().error == "\(processFailure)\n\(outputFailure)")

    let missingUsageDescription = fixture.presentation(hasUsageDescription: false).mixerSnapshot()
    #expect(missingUsageDescription.captureNotice?.message != processFailure)
    #expect(missingUsageDescription.error == "\(processFailure)\n\(outputFailure)")
    await fixture.expectPassivePorts()
  }

  @Test("Eight device actions use the same Common port and failure notices retain their reasons")
  func deviceActionsAndFailureProjection() async throws {
    let fixture = try RootPresentationFixture()
    defer { fixture.cleanUp() }
    let presentation = fixture.presentation()
    let actions = presentation.deviceActions
    actions.setDefault(.input, "mic")
    actions.setVolume(.output, "speaker", 0.25)
    #expect(
      fixture.effects.commands == [
        .setDefaultDevice(scope: .input, uid: "mic"),
        .setDeviceGain(scope: .output, uid: "speaker", gain: 0.25),
      ])
    actions.setMute(.input, "mic", true)
    actions.setHidden(.output, "speaker", true)
    actions.setPriority(.input, ["mic", "gone"])
    actions.setIcon("speaker", "music.note")
    actions.setVolumeOverride("speaker", .software)
    actions.stepVolume(.output, "speaker", false, true)
    #expect(
      fixture.effects.commands == [
        .setDefaultDevice(scope: .input, uid: "mic"),
        .setDeviceGain(scope: .output, uid: "speaker", gain: 0.25),
        .setDeviceMuted(scope: .input, uid: "mic", muted: true),
        .setDeviceHidden(scope: .output, uid: "speaker", hidden: true),
        .setDevicePriority(scope: .input, connectedUIDs: ["mic", "gone"]),
        .setDeviceIcon(uid: "speaker", symbol: "music.note"),
        .setDeviceVolumeOverride(uid: "speaker", tier: .software),
        .stepDeviceVolume(scope: .output, uid: "speaker", isUp: false, shift: true),
      ])
    let reason = "Shared external observation unavailable"
    fixture.effects.commandFailure = AudioRouteFailure(
      kind: .unavailable, stage: "unit-device", message: reason)
    actions.setDefault(.output, "speaker")
    fixture.graph.controller.observeApplications([], failure: reason)
    fixture.graph.controller.observeOutputs([], defaultUID: nil, failure: reason)
    #expect(fixture.graph.controller.commandFailure?.message == reason)
    #expect(presentation.mixerSnapshot().error == nil)
    #expect(presentation.settingsSnapshot().error == reason)
    #expect(presentation.mixerSnapshot().captureNotice?.message == reason)
    #expect(presentation.mixerSnapshot().captureNotice?.action == nil)
    await fixture.expectPassivePorts()

    fixture.effects.commandFailure = nil
    fixture.processes.apps = [fixture.app(id: 101, uid: "unit.live", name: "Player")]
    fixture.graph.engine.ingestObservations()
    fixture.graph.controller.observeOutputs(
      [
        AudioOutputDescriptor(
          uid: "speaker", bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 0.5, isMuted: false)
      ], defaultUID: "speaker")
    fixture.graph.controller.perform(.requestCaptureStart)
    await fixture.graph.controller.waitForCurrentWork()
    #expect(fixture.effects.nativeResolutions == 1)
    #expect(fixture.graph.controller.knownPermissionDenied)
    // Explicit Engine ingestion above may query its external HAL port; VM reads may not add any.
    let halBeforeSnapshot = fixture.hal.calls
    let denied = presentation.mixerSnapshot()
    #expect(denied.captureNotice?.action == .openSettings)
    #expect(denied.captureNotice?.message.contains("denied") == true)
    #expect(denied.error?.contains("Unit capture denied before native I/O") == true)
    #expect(!presentation.settingsSnapshot().isAccessibilityTrusted)
    #expect(fixture.hal.calls == halBeforeSnapshot && fixture.hal.loginCalls == 0)
    print(
      "RootPresentation denied snapshot HAL: before=\(halBeforeSnapshot), after=\(fixture.hal.calls)"
    )
    #expect(fixture.effects.nativeResolutions == 1)
    #expect(await fixture.transport.calls == 0)
    await fixture.graph.controller.shutdown()
  }
}

@MainActor
private final class RootPresentationFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "FineTuneRootPresentation-\(UUID().uuidString)", isDirectory: true)
  let devices = PresentationDevices()
  let processes = PresentationProcesses()
  let hal = PresentationHAL()
  let transport = PresentationTransport()
  let trust = PresentationTrust()
  let mediaKeys = MediaKeyStatus()
  let effects = PresentationEffects()
  let settings: SettingsManager
  let output: CoreAudioDeviceVolumeAdapter
  let model: DeviceControlModel
  let native: NativeAudioRoutingRuntime
  let graph: ApplicationGraph
  let lifecycle: LifecycleCoordinator
  var inactiveIcons: [String: NSImage] = [:]

  init(
    runtime: (any AudioRoutingRuntime)? = nil,
    captureFailure: AudioRouteFailure = AudioRouteFailure(
      kind: .permissionDenied, stage: "unit-native-preflight",
      message: "Unit capture denied before native I/O")
  ) throws {
    settings = SettingsManager(directory: directory, launchAtLoginService: hal)
    let clock = DeviceBackendClock { _ in throw CancellationError() }
    let ddc = DDCVolumeBackend(
      transport: transport, preferences: settings, candidates: { [] },
      displayChanges: PresentationDisplayChanges(), clock: clock)
    output = CoreAudioDeviceVolumeAdapter(
      deviceProvider: devices, settingsManager: settings, reader: hal, writer: hal,
      observer: hal, ddcController: ddc)
    model = DeviceControlModel(
      settings: settings, devices: devices, output: output,
      input: InputDeviceBackend(deviceProvider: devices, reader: hal, writer: hal, observer: hal),
      systemSounds: SystemSoundBackend(
        deviceProvider: devices, reader: hal, writer: hal, observer: hal),
      alertVolume: AlertVolumeBackend(scriptRunner: transport, clock: clock),
      bluetooth: BluetoothDeviceBackend(transport: transport, clock: clock), ddc: ddc, reader: hal,
      selectPreferredInput: { _ in Issue.record("Projection must not select an input") },
      inputPreferencesDidChange: { Issue.record("Projection must not run input policy") },
      selectDefaultOutput: { _ in Issue.record("Projection must not select an output") },
      outputPreferencesDidChange: { Issue.record("Projection must not run output policy") })
    let effects = effects
    native = NativeAudioRoutingRuntime { _, _ in
      effects.nativeResolutions += 1
      // Exercise Control's public failure path, but never reach a native capture/TCC call.
      throw captureFailure
    }
    graph = ApplicationGraph(
      settings: settings,
      profiles: try AutoEQProfileRepository(
        directory: directory.appendingPathComponent("Profiles"), cache: AutoEQProfileCache(),
        transport: transport),
      devices: devices, processes: processes, volumes: output, runtime: runtime ?? native,
      readOutputFailure: { nil }, readDefaultRoutingDecision: { .followObserved },
      deviceCommand: { command in
        effects.commands.append(command)
        if let failure = effects.commandFailure { throw failure }
      })
    lifecycle = LifecycleCoordinator(
      settings: settings,
      ports: LifecyclePorts(
        start: { effects.starts += 1 }, shutdown: { effects.stops += 1 },
        suspendAudio: { Issue.record("Projection must not suspend audio") },
        resumeAudio: { Issue.record("Projection must not resume audio") },
        suspendInput: { Issue.record("Projection must not suspend input") },
        resumeInput: { Issue.record("Projection must not resume input") }))
  }

  func presentation(hasUsageDescription: Bool = true) -> RootPresentation {
    RootPresentation(
      graph: graph, devices: model, native: native, accessibility: trust,
      mediaKeyStatus: mediaKeys, lifecycle: lifecycle,
      hasCaptureUsageDescription: hasUsageDescription,
      applicationIcon: { [unowned self] bundleID in bundleID.flatMap { inactiveIcons[$0] } })
  }

  func app(id: pid_t, uid: String, name: String) -> AudioApp {
    AudioApp(
      id: id, processObjectIDs: [UInt32(id) + 700], name: name,
      icon: NSImage(size: NSSize(width: 1, height: 1)), bundleID: uid,
      processRevision: processes.revision)
  }

  func expectPassivePorts(halBaseline: Int = 0) async {
    #expect(hal.calls == halBaseline && hal.loginCalls == 0)
    #expect(devices.starts == 0 && processes.starts == 0)
    #expect(effects.starts == 0 && effects.stops == 0 && effects.nativeResolutions == 0)
    #expect(trust.refreshes == 0 && !model.isRunning && lifecycle.phase == .idle)
    #expect(await transport.calls == 0)
  }

  func cleanUp() {
    settings.flushSync()
    let base = FileManager.default.temporaryDirectory.standardizedFileURL
    precondition(directory.deletingLastPathComponent().standardizedFileURL == base)
    precondition(directory.lastPathComponent.hasPrefix("FineTuneRootPresentation-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class PresentationEffects {
  var commands: [AudioCommand] = []
  var commandFailure: AudioRouteFailure?
  var nativeResolutions = 0
  var starts = 0
  var stops = 0
}

@MainActor
private final class PresentationTrust: AccessibilityTrustProviding {
  var isTrusted = false
  var refreshes = 0
  func refresh() { refreshes += 1 }
}

@MainActor
private final class PresentationDevices: AudioDeviceObservationProviding {
  let outputDevices = [
    AudioDevice(
      id: 10, uid: "speaker", name: "Speaker", icon: nil,
      supportsAutoEQ: false, bindingRevision: 1)
  ]
  let inputDevices = [
    AudioDevice(
      id: 20, uid: "mic", name: "Microphone", icon: nil,
      supportsAutoEQ: false, bindingRevision: 1)
  ]
  var starts = 0
  var onObservationChanged: (() -> Void)?
  var onDeviceDisconnected: ((String, String) -> Void)?
  var onDeviceConnected: ((String, String) -> Void)?
  var onInputDeviceDisconnected: ((String, String) -> Void)?
  var onInputDeviceConnected: ((String, String) -> Void)?
  var observation: AudioDeviceObservationSnapshot {
    AudioDeviceObservationSnapshot(
      outputDevices: outputDevices, inputDevices: inputDevices,
      health: .healthy, revision: 1)
  }
  func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
  func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
  func start() { starts += 1 }
  func stop() { Issue.record("Projection must not stop discovery") }
}

@MainActor
private final class PresentationProcesses: AudioProcessObservationProviding {
  var apps: [AudioApp] = []
  var revision: UInt64 = 1
  var activeApps: [AudioApp] { apps }
  var starts = 0
  var onObservationChanged: (() -> Void)?
  var onAppsChanged: (([AudioApp]) -> Void)?
  var observation: AudioProcessObservationSnapshot {
    AudioProcessObservationSnapshot(activeApps: apps, health: .healthy, revision: revision)
  }
  func start() { starts += 1 }
  func stop() { Issue.record("Projection must not stop process discovery") }
}

nonisolated private final class PresentationHAL: AudioDevicePropertyReading,
  AudioDevicePropertyWriting, AudioDevicePropertyObserving, LaunchAtLoginService
{
  var calls = 0
  var loginCalls = 0
  var isEnabled: Bool {
    loginCalls += 1
    return false
  }
  func setEnabled(_ enabled: Bool) throws {
    loginCalls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> Value {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readArray<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    initial: Value
  ) throws -> [Value] {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func hasProperty(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) -> Bool {
    calls += 1
    return false
  }
  func isPropertySettable(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
  ) throws -> Bool {
    calls += 1
    return false
  }
  func writeScalar<Value: BitwiseCopyable>(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
    value: Value
  ) throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  @MainActor func observe(
    _ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, onChange: @escaping @MainActor @Sendable () -> Void
  ) throws -> DevicePropertyObservation {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
}

private actor PresentationTransport: DeviceScriptRunning, BluetoothDeviceTransport,
  DDCDisplayTransport, ProfileHTTPTransport
{
  private(set) var calls = 0
  func run(script: String) async throws -> DeviceScriptResult {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func snapshot() async throws -> BluetoothTransportSnapshot {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func connect(id: String) async throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  @MainActor func observePowerChanges(_ onChange: @escaping @MainActor @Sendable () -> Void)
    -> DevicePropertyObservation
  {
    Issue.record("Projection must not register Bluetooth observers")
    return DevicePropertyObservation {}
  }
  func discover() async throws -> [DDCDisplaySnapshot] {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func writeVolume(displayID: UUID, percent: Int) async throws -> DDCVCPValue {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func readVolume(displayID: UUID) async throws -> DDCVCPValue {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func close() async throws {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    calls += 1
    throw PresentationFailure.unexpectedIO
  }
}

@MainActor
private struct PresentationDisplayChanges: DisplayParameterObserving {
  func observe(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DevicePropertyObservation {
    Issue.record("Projection must not register display observers")
    return DevicePropertyObservation {}
  }
}

private enum PresentationFailure: Error { case unexpectedIO }
