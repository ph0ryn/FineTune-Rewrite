import AppKit
import Darwin
import Foundation

/// Optional private read-only API, with the signature found in the fixed comparison source.
/// Finding a symbol does NOT prove its ABI or behavior on this OS. Live ABI is unverified.
/// Automated grouping tests inject metadata and never load or invoke this function.
@MainActor
final class ProcessResponsibilityLookup {
  private typealias Function = @convention(c) (pid_t) -> pid_t
  private var attempted = false
  private var handle: UnsafeMutableRawPointer?
  private var function: Function?

  init() {}

  func responsiblePID(for pid: pid_t) -> pid_t? {
    guard pid > 0 else { return nil }
    if !attempted {
      attempted = true
      // A normal SDK loader handle, retained for the entire lifetime of the function pointer.
      handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL)
      if let handle, let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") {
        function = unsafeBitCast(symbol, to: Function.self)
      }
    }
    guard let function else { return nil }
    let answer = function(pid)
    return answer > 0 && answer != pid ? answer : nil
  }

  isolated deinit { if let handle { dlclose(handle) } }
}

@MainActor
final class SystemAudioProcessMetadata: AudioProcessMetadataReading {
  private let responsibility: ProcessResponsibilityLookup
  init(responsibility: ProcessResponsibilityLookup = ProcessResponsibilityLookup()) {
    self.responsibility = responsibility
  }

  func applications() throws -> [ProcessApplicationMetadata] {
    NSWorkspace.shared.runningApplications.map {
      // Background helper .app bundles must not mask their real owner merely due to the suffix.
      let app = $0.bundleURL?.pathExtension == "app" && $0.activationPolicy != .prohibited
      return ProcessApplicationMetadata(
        pid: $0.processIdentifier, name: $0.localizedName, bundleID: $0.bundleIdentifier,
        icon: $0.icon, isApplication: app)
    }
  }

  func processName(for pid: pid_t) throws -> String? { ProcessNameLookup.name(for: pid) }

  func responsiblePID(for pid: pid_t) -> pid_t? { responsibility.responsiblePID(for: pid) }

  func parentPID(of pid: pid_t) throws -> pid_t? {
    guard pid > 1 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var selector: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let status = sysctl(&selector, 4, &info, &size, nil, 0)
    guard status == 0 else {
      if errno == ESRCH { return nil }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard size > 0 else { return nil }
    guard size == MemoryLayout<kinfo_proc>.size else {
      throw AudioObservationFailure(message: "The parent-process record has an unsupported layout.")
    }
    return info.kp_eproc.e_ppid > 0 ? info.kp_eproc.e_ppid : nil
  }
}
