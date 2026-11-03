import AppKit
import AudioToolbox

/// One immutable owner projection supplies UI metadata and all raw capture members together.
@MainActor
struct AudioProcessGrouper {
  // A presentation resource, not fresh OS metadata on every periodic acquisition.
  private static let fallbackIcon =
    NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()

  private enum Owner {
    case app(ProcessApplicationMetadata)
    case standalone, excluded
  }

  func group(
    _ processes: [AudioProcessRecord], metadata: any AudioProcessMetadataReading, currentPID: pid_t
  ) throws -> [AudioApp] {
    guard currentPID > 0 else {
      throw AudioObservationFailure(message: "The observer has no valid process identity.")
    }
    var applications: [pid_t: ProcessApplicationMetadata] = [:]
    for app in try metadata.applications() {
      guard app.pid > 0, applications[app.pid] == nil else {
        throw AudioObservationFailure(
          message: "Application metadata has an invalid or duplicate process identity.")
      }
      applications[app.pid] = app
    }
    var apps: [pid_t: AudioApp] = [:]
    var objectOwners: [AudioObjectID: pid_t] = [:]
    for process in processes {
      guard process.isRunning, process.pid != currentPID else { continue }
      guard process.pid > 0, process.objectID.isValid else {
        throw AudioObservationFailure(
          message: "The audio process inventory contains an invalid binding.")
      }
      if let previous = objectOwners[process.objectID], previous != process.pid {
        throw AudioObservationFailure(
          message: "An audio object changed process identity during discovery.")
      }
      objectOwners[process.objectID] = process.pid
      let owner = try resolve(
        process.pid, applications: applications, metadata: metadata, currentPID: currentPID)
      let info: ProcessApplicationMetadata?
      switch owner {
      case .excluded: continue
      case .app(let app): info = app
      case .standalone: info = applications[process.pid]
      }
      let pid = if let info, info.isApplication { info.pid } else { process.pid }
      let bundleID = info?.bundleID ?? process.bundleID
      if bundleID?.isEmpty == true {
        throw AudioObservationFailure(
          message: "An audio process returned an empty bundle identifier.")
      }
      let name =
        try info?.name ?? metadata.processName(for: process.pid)
        ?? bundleID?.components(separatedBy: ".").last
      guard let name, !name.isEmpty else {
        throw AudioObservationFailure(
          message: "Cannot resolve audio process metadata for PID \(process.pid).")
      }
      guard !SystemAudioDaemonCatalog.contains(bundleID: bundleID, name: name) else { continue }
      let helper = pid != process.pid
      if let existing = apps[pid] {
        guard existing.bundleID == bundleID else {
          throw AudioObservationFailure(
            message: "Conflicting saved identities were observed for PID \(pid).")
        }
        let ids = Set(existing.processObjectIDs + [process.objectID]).sorted()
        apps[pid] = AudioApp(
          id: pid, processObjectIDs: ids, name: existing.name, icon: existing.icon,
          bundleID: existing.bundleID, isHelperBacked: existing.isHelperBacked || helper)
      } else {
        let icon = info?.icon ?? Self.fallbackIcon
        apps[pid] = AudioApp(
          id: pid, processObjectIDs: [process.objectID], name: name, icon: icon, bundleID: bundleID,
          isHelperBacked: helper)
      }
    }
    return apps.values.sorted {
      let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
      return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
    }
  }

  private func resolve(
    _ pid: pid_t, applications: [pid_t: ProcessApplicationMetadata],
    metadata: any AudioProcessMetadataReading, currentPID: pid_t
  ) throws -> Owner {
    if let direct = applications[pid], direct.isApplication { return .app(direct) }
    if let responsible = metadata.responsiblePID(for: pid), responsible > 0, responsible != pid {
      if responsible == currentPID { return .excluded }
      if let app = applications[responsible], app.isApplication { return .app(app) }
    }
    var visited = Set<pid_t>()
    var candidate = pid
    while candidate > 1, visited.insert(candidate).inserted {
      if candidate == currentPID { return .excluded }
      if let app = applications[candidate], app.isApplication { return .app(app) }
      guard let parent = try metadata.parentPID(of: candidate), parent > 0 else { break }
      candidate = parent
    }
    return .standalone
  }
}
