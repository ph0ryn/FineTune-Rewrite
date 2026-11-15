import AppTestSupport
import FineTuneControl
import FineTuneDomain
import Testing
@testable import FineTune

@Suite("Main-executable capture metadata admission")
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
    // Keep this identity comparison out of #expect: the Swift 6.3.3 SILGen used by CI crashes on
    // the reabstraction thunk that the macro's autoclosure produces for a class-bound existential.
    let isOwnedHandle = (prepared as AnyObject) === native.handle("A")
    #expect(isOwnedHandle)
    #expect(prepared.key == request.key)
  }
}
