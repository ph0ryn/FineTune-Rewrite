import FineTuneDomain

/// Identity of one independently owned output execution, not an OS object identifier.
public struct AudioRouteKey: Hashable, Sendable {
  public let appIdentifier: String
  public let deviceUID: String
  public let generation: UInt64

  public init(appIdentifier: String, deviceUID: String, generation: UInt64) {
    self.appIdentifier = appIdentifier
    self.deviceUID = deviceUID
    self.generation = generation
  }
}

/// User intent is not an observation that macOS has granted recording permission.
public enum AudioCaptureIntent: Equatable, Sendable {
  case none
  case userInitiated(sessionID: UInt64)
}

/// Complete values for one UID. Mutable processors and their histories are native-owned.
public struct AudioOutputState: Equatable, Sendable {
  public var revision: UInt64
  public var effectiveGain: Float
  public var isMuted: Bool
  public var processing: TapInitialState

  public init(
    revision: UInt64, effectiveGain: Float, isMuted: Bool, processing: TapInitialState
  ) {
    self.revision = revision
    self.effectiveGain = effectiveGain
    self.isMuted = isMuted
    self.processing = processing
  }
}

/// The nonblocking gain/mute path; other processing preparation remains non-real-time.
public struct AudioOutputLevels: Equatable, Sendable {
  public let revision: UInt64
  public let effectiveGain: Float
  public let isMuted: Bool
  /// Unboosted app/device volume; not recoverable from final PCM gain on hardware/DDC outputs.
  public let effectiveLoudnessVolume: Float

  public init(
    revision: UInt64, effectiveGain: Float, isMuted: Bool, effectiveLoudnessVolume: Float
  ) {
    self.revision = revision
    self.effectiveGain = effectiveGain
    self.isMuted = isMuted
    self.effectiveLoudnessVolume = effectiveLoudnessVolume
  }
}

public struct AudioRouteRequest: Equatable, Sendable {
  public let key: AudioRouteKey
  /// Opaque revision of the shared Platform app/process group, never raw HAL process objects.
  public let processRevision: UInt64
  public let initialState: AudioOutputState
  public let captureIntent: AudioCaptureIntent

  public init(
    key: AudioRouteKey, processRevision: UInt64, initialState: AudioOutputState,
    captureIntent: AudioCaptureIntent
  ) {
    self.key = key
    self.processRevision = processRevision
    self.initialState = initialState
    self.captureIntent = captureIntent
  }
}

public enum AudioRoutePhase: Equatable, Sendable {
  case prepared, accepted, started, armed, committed, firstApplied, retiring, retired, failed
}

/// Policy-relevant classification comes from the adapter, never from parsing an OS error string.
public enum AudioRouteFailureKind: Equatable, Sendable {
  case unavailable, captureNotRequested, permissionDenied, unsupported, bindingChanged, cancelled
  case nativeFailure
}

public struct AudioRouteFailure: Error, Equatable, Sendable {
  public let kind: AudioRouteFailureKind
  public let stage: String
  public let code: Int32?
  public let message: String

  public init(
    kind: AudioRouteFailureKind = .nativeFailure, stage: String, code: Int32? = nil, message: String
  ) {
    self.kind = kind
    self.stage = stage
    self.code = code
    self.message = message
  }
}

/// Start, valid callback, commit and applied state are separate observations, not permission proof.
public struct AudioRouteObservation: Equatable, Sendable {
  public let key: AudioRouteKey
  public let phase: AudioRoutePhase
  public let acceptedRevision: UInt64?
  public let appliedRevision: UInt64?
  public let failure: AudioRouteFailure?
  public let cleanupFailure: AudioRouteFailure?
  /// Latest observed post-output amplitude, not a freshness or permission guarantee.
  /// Nil until a permitted buffer was processed, or when the observation is unavailable.
  public let peakLevel: Float?

  public init(
    key: AudioRouteKey, phase: AudioRoutePhase, acceptedRevision: UInt64? = nil,
    appliedRevision: UInt64? = nil, failure: AudioRouteFailure? = nil,
    cleanupFailure: AudioRouteFailure? = nil, peakLevel: Float? = nil
  ) {
    self.key = key
    self.phase = phase
    self.acceptedRevision = acceptedRevision
    self.appliedRevision = appliedRevision
    self.failure = failure
    self.cleanupFailure = cleanupFailure
    self.peakLevel = peakLevel
  }
}

public enum AudioRetirementResult: Equatable, Sendable {
  case retired
  case pending
  case failed(AudioRouteFailure)
}

/// Resolves one current app group and one output UID. No OS acquisition without explicit live intent.
@MainActor
public protocol AudioRoutingRuntime: AnyObject {
  /// Explicitly retries terminal cleanup retained without a PreparedAudioRoute handle.
  /// This does not grant capture; preparations must wait for any in-flight retry to settle.
  func requestCleanupRetry()
  func prepare(_ request: AudioRouteRequest) async throws -> any PreparedAudioRoute
}

/// A single UID's native owner; methods never execute blocking HAL work on MainActor.
@MainActor
public protocol PreparedAudioRoute: AnyObject {
  var key: AudioRouteKey { get }
  var onObservation: (@MainActor (AudioRouteObservation) -> Void)? { get set }

  /// Replacement starts without render permission. Control retains old routes until armed.
  func startMuted(state: AudioOutputState) async throws -> AudioRouteObservation
  /// Initial routes start at target gain; replacements open only after old retirement succeeds.
  func commit(state: AudioOutputState) async throws -> AudioRouteObservation
  /// Accepted configuration is not necessarily applied until a later buffer-boundary observation.
  func update(state: AudioOutputState) async throws -> AudioRouteObservation
  /// Publishes levels without HAL calls, coefficient preparation, or history reset.
  func requestLevels(_ levels: AudioOutputLevels)
  /// Cancels admission through a lifetime-protected ticket; does not free live callback state.
  func cancel()
  /// Pending/error owners remain retained until a retired observation confirms quiescence.
  /// A terminal failure may be retried explicitly, but in-flight/PENDING calls must be joined.
  /// During retirement, observations report this attempt's cleanup errors rather than replaying
  /// historical cleanup diagnostics. A repeated identical current error is still a failure.
  func retire() async -> AudioRetirementResult
}
