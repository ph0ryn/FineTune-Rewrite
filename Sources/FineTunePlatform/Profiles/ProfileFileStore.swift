import Foundation

public struct CachedAutoEQCatalog: Equatable, Sendable {
  public let entries: [AutoEQCatalogEntry]
  public let modifiedAt: Date

  public init(entries: [AutoEQCatalogEntry], modifiedAt: Date) {
    self.entries = entries
    self.modifiedAt = modifiedAt
  }
}

public struct ImportedProfileText: Sendable {
  public let id: String
  public let name: String
  public let text: String

  public init(id: String, name: String, text: String) {
    self.id = id
    self.name = name
    self.text = text
  }
}

@MainActor
public protocol ProfileFileStoring: AnyObject {
  func readCatalog() throws -> CachedAutoEQCatalog?
  func writeCatalog(_ entries: [AutoEQCatalogEntry]) throws
  func readFetchedText(id: String) throws -> String?
  func writeFetchedText(_ text: String, id: String) throws
  func readImportedProfiles() throws -> [ImportedProfileText]
  func readImportText(from url: URL) throws -> String
  func writeImportedProfile(text: String, name: String, id: String) throws
  func removeImportedProfile(id: String) throws
}

/// The root is supplied by composition, never inferred from the original application's namespace.
/// Construction only validates the URL; it performs no filesystem operations.
@MainActor
public final class ProfileFileStore: ProfileFileStoring {
  public let directory: URL
  private var importsDirectory: URL {
    directory.appendingPathComponent("AutoEQ", isDirectory: true)
  }
  private var fetchedDirectory: URL {
    importsDirectory.appendingPathComponent("fetched", isDirectory: true)
  }
  private var catalogURL: URL { directory.appendingPathComponent("autoeq-catalog.json") }

  public init(directory: URL) throws {
    guard directory.isFileURL else {
      throw ProfileRepositoryError.invalidRoot(directory.absoluteString)
    }
    self.directory = directory.standardizedFileURL
  }

  public func readCatalog() throws -> CachedAutoEQCatalog? {
    guard let data = try allowingMissingFile({ try Data(contentsOf: catalogURL) }) else {
      return nil
    }
    let entries = try JSONDecoder().decode([AutoEQCatalogEntry].self, from: data)
    let attributes = try FileManager.default.attributesOfItem(atPath: catalogURL.path)
    guard let modifiedAt = attributes[.modificationDate] as? Date else {
      throw ProfileRepositoryError.missingModificationDate
    }
    return CachedAutoEQCatalog(entries: entries, modifiedAt: modifiedAt)
  }

  public func writeCatalog(_ entries: [AutoEQCatalogEntry]) throws {
    let data = try JSONEncoder().encode(entries)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: catalogURL, options: .atomic)
  }

  public func readFetchedText(id: String) throws -> String? {
    let url = try profileURL(directory: fetchedDirectory, id: id, extension: "txt")
    return try allowingMissingFile { try String(contentsOf: url, encoding: .utf8) }
  }

  public func writeFetchedText(_ text: String, id: String) throws {
    let url = try profileURL(directory: fetchedDirectory, id: id, extension: "txt")
    try FileManager.default.createDirectory(at: fetchedDirectory, withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  public func readImportedProfiles() throws -> [ImportedProfileText] {
    guard
      let contents = try allowingMissingFile({
        try FileManager.default.contentsOfDirectory(
          at: importsDirectory, includingPropertiesForKeys: nil)
      })
    else { return [] }
    let files = contents.filter { $0.pathExtension == "txt" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try files.map { file in
      let id = file.deletingPathExtension().lastPathComponent
      let nameURL = try profileURL(directory: importsDirectory, id: id, extension: "name")
      let text = try String(contentsOf: file, encoding: .utf8)
      let name =
        try allowingMissingFile { try String(contentsOf: nameURL, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? id
      return ImportedProfileText(id: id, name: name, text: text)
    }
  }

  public func readImportText(from url: URL) throws -> String {
    guard url.isFileURL else {
      throw ProfileRepositoryError.invalidImportURL(url.absoluteString)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  public func writeImportedProfile(text: String, name: String, id: String) throws {
    let nameURL = try profileURL(directory: importsDirectory, id: id, extension: "name")
    let textURL = try profileURL(directory: importsDirectory, id: id, extension: "txt")
    try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
    try name.write(to: nameURL, atomically: true, encoding: .utf8)
    // The content file is the reload-visible commit point; an orphan name is not a profile.
    try text.write(to: textURL, atomically: true, encoding: .utf8)
  }

  public func removeImportedProfile(id: String) throws {
    let nameURL = try profileURL(directory: importsDirectory, id: id, extension: "name")
    let textURL = try profileURL(directory: importsDirectory, id: id, extension: "txt")
    for url in [nameURL, textURL] {
      _ = try allowingMissingFile { try FileManager.default.removeItem(at: url) }
    }
  }

  /// Only a documented missing-file error means absence; permission/path/I/O failures stay thrown.
  private func allowingMissingFile<Value>(_ operation: () throws -> Value) throws -> Value? {
    do {
      return try operation()
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      return nil
    }
  }

  private func profileURL(directory: URL, id: String, extension suffix: String) throws -> URL {
    try Self.validateIdentifier(id)
    return directory.appendingPathComponent(id).appendingPathExtension(suffix)
  }

  public static func validateIdentifier(_ id: String) throws {
    guard !id.isEmpty, id != ".", id != "..",
      !id.contains("/"), !id.contains("\\"), !id.contains("\0")
    else { throw ProfileRepositoryError.invalidIdentifier(id) }
  }
}
