import Darwin
import Dispatch
import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import NativeAudio

private let help = """
AudioProbe — read-only discovery by default; live capture requires explicit options.

  AudioProbe [--list]
  AudioProbe --describe <output-uid>
  AudioProbe --capture --app <saved-app-id> --process-revision <revision> \
    --output <output-uid> --seconds <duration> [--gain <0...1>]
  AudioProbe --help

--list prints the shared healthy device/process snapshots, including exact IDs/revisions.
--describe reads one output's format metadata. Neither mode captures or requests permission.
--capture captures the selected process group and renders it to the selected output.
The app is muted while tapped. EQ, AutoEQ and loudness processing are disabled; gain defaults
explicitly to unity. Duration must be greater than zero and at most 30 seconds. The duration
is an admission deadline including preparation/start, followed by at most 2 seconds of cleanup.
A blocked OS operation or failed/pending cleanup is reported before the process exits.
A configured main-bundle NSAudioCaptureUsageDescription is required before live preparation.
Started/armed/firstApplied are not statements that macOS granted recording permission.
"""

private enum ProbeError: Error, CustomStringConvertible {
  case invalid(String)
  var description: String { switch self { case .invalid(let text): text } }
}
private enum Command: Sendable {
  case help, list, describe(String)
  case capture(app: String, revision: UInt64, output: String, seconds: Double, gain: Float)

  static func parse(_ arguments: [String]) throws -> Command {
    if arguments.isEmpty || arguments == ["--list"] { return .list }
    if arguments == ["--help"] || arguments == ["-h"] { return .help }
    if arguments.count == 2 && arguments[0] == "--describe" && !arguments[1].isEmpty {
      return .describe(arguments[1])
    }
    guard arguments.first == "--capture", arguments.count % 2 == 1 else {
      throw ProbeError.invalid("Use --help to choose a read-only command or explicit capture options.")
    }
    var values: [String: String] = [:]
    let allowed: Set<String> = ["--app", "--process-revision", "--output", "--seconds", "--gain"]
    var index = 1
    while index < arguments.count {
      let key = arguments[index]
      guard allowed.contains(key), values[key] == nil else {
        throw ProbeError.invalid("Unknown or duplicate option: \(key)")
      }
      values[key] = arguments[index + 1]
      index += 2
    }
    guard let app = values["--app"], !app.isEmpty,
      let revisionText = values["--process-revision"], let revision = UInt64(revisionText), revision > 0,
      let output = values["--output"], !output.isEmpty,
      let durationText = values["--seconds"], let seconds = Double(durationText),
      seconds.isFinite, seconds > 0, seconds <= 30,
      let gain = Float(values["--gain"] ?? "1"), gain.isFinite, gain >= 0, gain <= 1
    else {
      throw ProbeError.invalid("Capture requires an exact app/revision, output UID, duration in (0, 30], and gain in [0, 1].")
    }
    return .capture(app: app, revision: revision, output: output, seconds: seconds, gain: gain)
  }
}

private func writeJSON(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([0x0A]))
}
private func fail(_ error: any Error) -> Never {
  FileHandle.standardError.write(Data("AudioProbe: \(error)\n".utf8))
  Darwin.exit(EXIT_FAILURE)
}

@MainActor
private final class CaptureSession {
  var route: (any PreparedAudioRoute)?
  var work: Task<Void, Never>?
  private var timer: DispatchSourceTimer?
  private var closing = false
  private var exitCode: Int32 = 0
  private var hasAppliedCallback = false

  func startDeadline(seconds: Double) {
    let source = DispatchSource.makeTimerSource(queue: .main)
    source.schedule(deadline: .now() + seconds)
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in self?.finish(code: 0) }
    }
    timer = source
    source.resume()
  }

  func observe(_ observation: AudioRouteObservation) {
    if let applied = observation.appliedRevision, applied > 0 { hasAppliedCallback = true }
    do {
      try writeJSON([
        "phase": String(describing: observation.phase),
        "acceptedRevision": observation.acceptedRevision as Any? ?? NSNull(),
        "appliedRevision": observation.appliedRevision as Any? ?? NSNull(),
        "failure": observation.failure.map { "\($0.stage): \($0.message)" } as Any? ?? NSNull(),
        "cleanupFailure": observation.cleanupFailure.map { "\($0.stage): \($0.message)" } as Any? ?? NSNull(),
      ])
    } catch { fail(error) }
    if closing && observation.phase == .retired { Darwin.exit(completedExitCode()) }
    if !closing && observation.phase == .failed { finish(code: EXIT_FAILURE) }
  }

  private func completedExitCode() -> Int32 {
    guard exitCode == EXIT_SUCCESS && !hasAppliedCallback else { return exitCode }
    FileHandle.standardError.write(Data("AudioProbe: No valid permitted callback was observed; recording authorization remains unknown.\n".utf8))
    return EXIT_FAILURE
  }

  func finish(code: Int32) {
    guard !closing else { return }
    closing = true
    exitCode = code
    timer?.cancel()
    timer = nil
    work?.cancel()
    route?.cancel()
    // CLI-only hard bound. Never free a live native owner to satisfy a timer: if the OS
    // cannot finish teardown, preserve the diagnostic and end the owning process instead.
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      FileHandle.standardError.write(Data("AudioProbe: Native cleanup did not finish before the process deadline.\n".utf8))
      Darwin._exit(EXIT_FAILURE)
    }
    guard let route else {
      FileHandle.standardError.write(Data("AudioProbe: No owned route was available for retirement.\n".utf8))
      Darwin.exit(EXIT_FAILURE)
    }
    Task { @MainActor in
      switch await route.retire() {
      case .retired: Darwin.exit(completedExitCode())
      case .pending: break // Native monitor reports actual retired, never a fixed-delay assumption.
      case .failed(let error): fail(error)
      }
    }
  }
}

@MainActor
private func run(_ command: Command) async throws {
  switch command {
  case .help:
    print(help)
    Darwin.exit(EXIT_SUCCESS)
  case .list:
    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    devices.refresh()
    processes.refresh()
    guard devices.observation.health == .healthy, processes.observation.health == .healthy else {
      throw ProbeError.invalid("Discovery failed: devices=\(devices.observation.health), processes=\(processes.observation.health)")
    }
    try writeJSON([
      "mode": "readOnly", "capture": false,
      "outputs": devices.outputDevices.map {
        ["uid": $0.uid, "name": $0.name, "bindingRevision": $0.bindingRevision,
         "formatRevision": $0.formatRevision] as [String: Any]
      },
      "apps": processes.activeApps.map {
        ["identifier": $0.persistenceIdentifier, "name": $0.name, "pid": $0.id,
         "processRevision": $0.processRevision, "processObjects": $0.processObjectIDs] as [String: Any]
      },
    ])
    Darwin.exit(EXIT_SUCCESS)
  case .describe(let uid):
    var description = FTNativeOutputDescription()
    var error = FTNativeError()
    let result = uid.withCString { ft_native_describe_output($0, &description, &error) }
    guard result == FT_NATIVE_OK else {
      throw ProbeError.invalid("Output description failed at operation \(error.operation.rawValue), code \(error.code).")
    }
    try writeJSON([
      "mode": "readOnly", "capture": false, "uid": uid,
      "objectID": description.object_id, "inputChannels": description.input_channels,
      "outputChannels": description.output_channels, "virtualSampleRate": description.virtual_sample_rate > 0 ? description.virtual_sample_rate as Any : NSNull(),
      "stereoFloat32Output": description.stereo_float32_supported,
    ])
    Darwin.exit(EXIT_SUCCESS)
  case .capture(let app, let revision, let uid, let seconds, let gain):
    guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") as? String,
      !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ProbeError.invalid("This build has no main-bundle audio capture usage description. Rebuild the configured AudioProbe target before using --capture.")
    }
    let processes = AudioProcessMonitor()
    processes.refresh()
    _ = try processes.resolveApp(identifier: app, processRevision: revision)
    let runtime = NativeAudioRoutingRuntime(resolveApp: { identifier, expected in
      try processes.resolveApp(identifier: identifier, processRevision: expected)
    })
    let session = CaptureSession()
    runtime.onCleanupFailure = { observation in session.observe(observation) }
    session.startDeadline(seconds: seconds)
    session.work = Task { @MainActor in
      do {
        let state = AudioOutputState(
          revision: 1, effectiveGain: gain, isMuted: false,
          processing: TapInitialState(eqSettings: EQSettings(isEnabled: false)))
        let route = try await runtime.prepare(AudioRouteRequest(
          key: AudioRouteKey(appIdentifier: app, deviceUID: uid, generation: 1),
          processRevision: revision, initialState: state,
          captureIntent: .userInitiated(sessionID: UInt64.random(in: 1...UInt64.max))))
        session.route = route
        route.onObservation = { observation in session.observe(observation) }
        _ = try await route.commit(state: state) // Initial no-old route: no startMuted/warmup drop.
      } catch {
        FileHandle.standardError.write(Data("AudioProbe: \(error)\n".utf8))
        session.finish(code: EXIT_FAILURE)
      }
    }
  }
}

// Parse before constructing a producer/runtime. --help and malformed arguments are OS-inert.
do {
  let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
  Task { @MainActor in
    do { try await run(command) } catch { fail(error) }
  }
  dispatchMain()
} catch { fail(error) }
