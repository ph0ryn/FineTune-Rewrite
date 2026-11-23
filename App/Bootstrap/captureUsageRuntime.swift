import FineTuneControl
import Foundation

/// Only the main executable's privacy metadata admits capture; a resource bundle is insufficient.
@MainActor
final class CaptureUsageRuntime: AudioRoutingRuntime {
  let runtime: any AudioRoutingRuntime
  let usageDescription: String?

  init(runtime: any AudioRoutingRuntime, usageDescription: String?) {
    self.runtime = runtime
    self.usageDescription = usageDescription
  }

  var isConfigured: Bool {
    guard let usageDescription else { return false }
    return !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // Cleanup closes existing owners and never admits a new capture, even without metadata.
  func requestCleanupRetry() { runtime.requestCleanupRetry() }

  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute {
    guard isConfigured else {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "capture-metadata",
        message: "Live audio is unavailable in this executable. Use the built FineTune-Rewrite app."
      )
    }
    return try await runtime.prepare(request)
  }
}
