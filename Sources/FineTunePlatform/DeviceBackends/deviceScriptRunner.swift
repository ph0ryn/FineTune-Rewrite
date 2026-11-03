import Foundation

public struct DeviceScriptResult: Equatable, Sendable {
  public let status: Int32
  /// Both stdout and stderr are drained through one pipe, including diagnostics on nonzero exit.
  public let output: String

  public init(status: Int32, output: String) {
    self.status = status
    self.output = output
  }
}

public protocol DeviceScriptRunning: Sendable {
  func run(script: String) async throws -> DeviceScriptResult
}

/// Explicit public-command host. Construction never starts a process or requests permission.
/// The queue serializes complete executions, not just Process.run(), so old writes cannot overtake.
public final class SystemDeviceScriptRunner: DeviceScriptRunning, Sendable {
  private let queue = DispatchQueue(label: "com.finetune-rewrite.alert-script", qos: .utility)

  public init() {}

  public func run(script: String) async throws -> DeviceScriptResult {
    let execution = ScriptExecution()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          let process = Process()
          let output = Pipe()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
          process.arguments = ["-e", script]
          process.standardInput = FileHandle.nullDevice
          process.standardOutput = output
          process.standardError = output
          defer { execution.finish() }
          do {
            try execution.prepare(process)
            try process.run()
            execution.didStart()
            // A single stream avoids the stdout/stderr pipe-backpressure deadlock.
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            try execution.checkCancellation()
            continuation.resume(
              returning: DeviceScriptResult(
                status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
          } catch {
            if process.isRunning {
              process.terminate()
              process.waitUntilExit()
            }
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      execution.cancel()
    }
  }
}

/// Only cancellation state and the owned child reference cross threads; all are under this lock.
private final class ScriptExecution: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?

  func prepare(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    self.process = process
  }

  func didStart() {
    lock.lock()
    defer { lock.unlock() }
    if cancelled, let process, process.isRunning { process.terminate() }
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    if let process, process.isRunning { process.terminate() }
  }

  func checkCancellation() throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }
    process = nil
  }
}
