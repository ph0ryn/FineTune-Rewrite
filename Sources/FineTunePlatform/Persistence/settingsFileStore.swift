import Foundation

/// A small throwing file boundary; the observable adapter decides how failures are presented.
struct SettingsFileStore: Sendable {
  let url: URL

  init(directory: URL) {
    url = directory.appendingPathComponent("settings.json")
  }

  func load() throws -> SavedSettings? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: url))
  }

  func backupInvalidFile() throws {
    let backupURL = url.deletingPathExtension().appendingPathExtension("backup.json")
    try Data(contentsOf: url).write(to: backupURL, options: .atomic)
  }

  func write(_ settings: SavedSettings) throws {
    let data = try JSONEncoder().encode(settings)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
