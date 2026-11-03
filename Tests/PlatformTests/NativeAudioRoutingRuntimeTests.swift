import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Testing

@Suite("Native audio factory boundary")
struct NativeAudioRoutingRuntimeTests {
  private func request(_ intent: AudioCaptureIntent) -> AudioRouteRequest {
    AudioRouteRequest(
      key: AudioRouteKey(appIdentifier: "fixture.app", deviceUID: "fixture-output", generation: 1),
      processRevision: 17,
      initialState: AudioOutputState(
        revision: 1, effectiveGain: 0.25, isMuted: false, processing: TapInitialState()),
      captureIntent: intent)
  }

  @Test @MainActor
  func constructionAndMissingIntentNeverResolveOrAcquire() async {
    var resolutions = 0
    let runtime = NativeAudioRoutingRuntime(resolveApp: { identifier, _ in
      resolutions += 1
      throw AudioAppObservationResolutionError.unavailable(identifier)
    })
    #expect(resolutions == 0)
    for intent in [AudioCaptureIntent.none, .userInitiated(sessionID: 0)] {
      do {
        _ = try await runtime.prepare(request(intent))
        Issue.record("Capture without an explicit nonzero session was accepted")
      } catch let error as AudioRouteFailure {
        #expect(error.kind == .captureNotRequested)
      } catch {
        Issue.record("Unexpected error: \(error)")
      }
    }
    #expect(resolutions == 0)
  }

  @Test @MainActor
  func unavailableSnapshotStopsBeforeTheNativeBoundary() async {
    var resolutions = 0
    let runtime = NativeAudioRoutingRuntime(resolveApp: { identifier, revision in
      resolutions += 1
      #expect(identifier == "fixture.app")
      #expect(revision == 17)
      throw AudioAppObservationResolutionError.unavailable(identifier)
    })
    do {
      _ = try await runtime.prepare(request(.userInitiated(sessionID: 7)))
      Issue.record("An unavailable app group was accepted")
    } catch let error as AudioRouteFailure {
      #expect(error.kind == .unavailable)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(resolutions == 1)
  }

  @Test @MainActor
  func staleBindingStopsBeforeTheNativeBoundary() async {
    let runtime = NativeAudioRoutingRuntime(resolveApp: { identifier, _ in
      throw AudioAppObservationResolutionError.bindingChanged(identifier)
    })
    do {
      _ = try await runtime.prepare(request(.userInitiated(sessionID: 7)))
      Issue.record("A stale app group was accepted")
    } catch let error as AudioRouteFailure {
      #expect(error.kind == .bindingChanged)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
