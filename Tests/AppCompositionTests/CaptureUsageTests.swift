import AppTestSupport
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import SwiftUI
import Testing

@testable import FineTune

@Suite("App composition: Capture metadata guard and settings capture transition")
@MainActor
struct CaptureUsageTests {
  private var request: AudioRouteRequest {
    AudioRouteRequest(
      key: AudioRouteKey(appIdentifier: "unit.active", deviceUID: "A", generation: 1),
      processRevision: 17,
      initialState: AudioOutputState(
        revision: 1, effectiveGain: 0.25, isMuted: false, processing: TapInitialState()),
      captureIntent: .userInitiated(sessionID: 7))
  }

  @Test(arguments: [String?](arrayLiteral: nil, "", " \n "))
  func missingDescriptionFailsBeforeNative(_ description: String?) async {
    let native = RoutingProbeRuntime()
    let runtime = CaptureUsageRuntime(runtime: native, usageDescription: description)
    runtime.requestCleanupRetry()
    #expect(native.cleanupRetryRequests == 1 && native.requests.isEmpty && native.handles.isEmpty)
    do {
      _ = try await runtime.prepare(request)
      Issue.record("Missing main-executable privacy metadata reached the native runtime")
    } catch let failure as AudioRouteFailure {
      #expect(failure.kind == .unavailable)
      #expect(failure.stage == "capture-metadata")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(native.requests.isEmpty)
  }

  @Test
  func configuredMainDelegatesTheExactRequestAndOwnedRoute() async throws {
    let native = RoutingProbeRuntime()
    let runtime = CaptureUsageRuntime(
      runtime: native, usageDescription: "Record selected app audio.")
    runtime.requestCleanupRetry()
    #expect(native.cleanupRetryRequests == 1 && native.requests.isEmpty && native.handles.isEmpty)
    let prepared = try await runtime.prepare(request)
    #expect(native.requests == [request])
    let isOwnedHandle = (prepared as AnyObject) === native.handle("A")
    #expect(isOwnedHandle)
    #expect(prepared.key == request.key)
  }

  @Test(
    "Settings live-audio binding drives capture intent and runtime start/stop through RootBindings")
  func liveAudioBindingDrivesCaptureIntentTransition() async throws {
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
    let device = DeviceSettingsPresentation(
      systemOutputUID: nil, systemOutputOptions: [], canSetSystemOutput: false,
      followsDefault: true, alertVolume: nil, canSetAlertVolume: false, alertIsApplying: false,
      alertVolumeSilenced: false, error: nil,
      bluetooth: BluetoothPresentation(isPoweredOn: true, paired: [], error: nil))
    let read = {
      SettingsSnapshot(
        settings: settings.appSettings, isAccessibilityTrusted: false, isMediaKeyOffline: false,
        error: controller.lastFailure?.message, device: device)
    }
    let actions = SettingsActions(
      updateSettings: root.updateSettings,
      recordShortcut: { _, _ in Issue.record("Capture editing must not register shortcuts.") },
      requestAccessibility: { Issue.record("Capture editing must not request Accessibility.") },
      retryMediaKeys: { Issue.record("Capture editing must not start media keys.") },
      resetAll: root.resetAllSettings,
      device: DeviceSettingsActions(
        setSystemOutput: { _ in Issue.record("Unexpected device call") },
        setSystemFollowDefault: { Issue.record("Unexpected device call") },
        setAlertVolume: { _ in Issue.record("Unexpected device call") },
        refreshBluetooth: { Issue.record("Unexpected device call") },
        connectBluetooth: { _ in Issue.record("Unexpected device call") }))
    func makeCaptureBinding() -> Binding<Bool> {
      SettingsBindings(snapshot: read(), actions: actions, readFresh: read)
        .field(\AppSettings.explicitUserCaptureEnabled)
    }
    var binding = makeCaptureBinding()

    #expect(!binding.wrappedValue && runtime.requests.isEmpty && controller.captureIntent == .none)
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
    binding = makeCaptureBinding()
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
    binding = makeCaptureBinding()
    #expect(!settings.appSettings.explicitUserCaptureEnabled && !binding.wrappedValue)
    #expect(controller.captureIntent == .none && route.cancelled)
    await controller.shutdown()
    #expect(route.retired && !route.rendering && runtime.requests.count == 1)
  }
}

@MainActor
private final class CaptureSettingsLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
