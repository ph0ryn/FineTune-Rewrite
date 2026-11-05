import Foundation

/// App lifecycle effects. Every capability is supplied by the production service
/// graph; individual services continue to own their observers and async work.
@MainActor
struct LifecyclePorts {
  let start: @MainActor () async throws -> Void
  let shutdown: @MainActor () async throws -> Void
  let suspendAudio: @MainActor () async throws -> Void
  let resumeAudio: @MainActor () async throws -> Void
  let suspendInput: @MainActor () -> Void
  let resumeInput: @MainActor () -> Void
}

enum LifecyclePhase: Equatable {
  case idle, starting, running, suspended, stopping, stopped, failed
}

enum LifecycleEvent {
  case systemWillSleep, systemDidWake, sessionResigned, sessionBecameActive
}
