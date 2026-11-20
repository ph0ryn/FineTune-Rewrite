import FineTuneDomain
import Foundation
import Observation

public enum ProfileCatalogState: Equatable, Sendable { case idle, loading, ready, failed }

/// Acquisition and persistence only. Device selections and live route reconciliation belong to Control.
/// The injected cache is the sole store of loaded profile values; the index contains display metadata.
@Observable
@MainActor
public final class AutoEQProfileRepository {
  public static let catalogTTL: TimeInterval = 7 * 24 * 3600
  public static let indexURL = URL(
    string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
  private static let profileBaseURL = URL(
    string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!

  private enum CatalogStatus {
    case idle, loading, ready
    case failed(any Error)
  }
  private enum DiskCatalogState {
    case unread, absent
    case present(Date)
  }
  private var status: CatalogStatus = .idle
  @ObservationIgnored private var diskCatalog: DiskCatalogState = .unread
  @ObservationIgnored private var catalogGeneration = 0

  public let cache: AutoEQProfileCache
  public private(set) var catalog: [AutoEQCatalogEntry] = []
  public var catalogState: ProfileCatalogState {
    switch status {
    case .idle: .idle
    case .loading: .loading
    case .ready: .ready
    case .failed: .failed
    }
  }
  public var catalogError: (any Error)? {
    if case .failed(let error) = status { return error }
    return nil
  }
  public private(set) var parseDiagnostics: [String: [ProfileParseDiagnostic]] = [:]

  private let files: any ProfileFileStoring
  private let transport: any ProfileHTTPTransport
  private let now: () -> Date
  private let makeImportedID: () -> String
  private var importedEntries: [AutoEQCatalogEntry] = []
  private var searchIndex = AutoEQSearchIndex(entries: [])
  // Observation marker for the externally owned cache, not a duplicate collection of profiles.
  private var cacheRevision = 0

  public init(
    cache: AutoEQProfileCache, files: any ProfileFileStoring,
    transport: any ProfileHTTPTransport = URLSessionProfileTransport(),
    now: @escaping () -> Date = Date.init,
    makeImportedID: @escaping () -> String = { UUID().uuidString }
  ) {
    self.cache = cache
    self.files = files
    self.transport = transport
    self.now = now
    self.makeImportedID = makeImportedID
  }

  public convenience init(
    directory: URL, cache: AutoEQProfileCache,
    transport: any ProfileHTTPTransport = URLSessionProfileTransport()
  ) throws {
    self.init(cache: cache, files: try ProfileFileStore(directory: directory), transport: transport)
  }

  public func profile(for id: String) -> AutoEQProfile? {
    _ = cacheRevision
    return cache.profile(for: id)
  }

  @discardableResult
  public func loadLocalProfiles(selectedProfileIDs: Set<String> = []) throws -> [String] {
    let records = try files.readImportedProfiles()
    let parsed = try records.map { record in
      try ProfileFileStore.validateIdentifier(record.id)
      return try ParametricEQTextParser.parse(
        text: record.text, name: record.name, source: .imported, id: record.id)
    }
    let ids = Set(parsed.map { $0.profile.id })
    for old in importedEntries where !ids.contains(old.id) {
      cache.remove(id: old.id)
      cacheRevision += 1
      parseDiagnostics[old.id] = nil
    }
    importedEntries = []
    for result in parsed {
      publish(result)
      importedEntries.append(importedEntry(result.profile))
    }
    rebuildIndex()
    var loadedIDs = parsed.map { $0.profile.id }
    if !selectedProfileIDs.isEmpty {
      do {
        _ = try loadCachedCatalog()
      } catch {
        status = .failed(error)
        throw error
      }
      // Per-profile read/parse failure does not invalidate otherwise usable catalog metadata.
      for id in selectedProfileIDs.sorted() {
        try ProfileFileStore.validateIdentifier(id)
        if cache.profile(for: id) != nil { continue }
        guard let entry = catalog.first(where: { $0.id == id }),
          let text = try files.readFetchedText(id: id)
        else { continue }
        publish(try parseFetched(text, entry: entry))
        loadedIDs.append(id)
      }
    }
    return loadedIDs
  }

  public func loadCatalog() async throws {
    catalogGeneration += 1
    let generation = catalogGeneration
    do {
      if let modifiedAt = try loadCachedCatalog(),
        now().timeIntervalSince(modifiedAt) <= Self.catalogTTL
      {
        status = .ready
        return
      }
      try await refreshCatalog()
    } catch {
      if catalogGeneration == generation { status = .failed(error) }
      throw error
    }
  }

  public func refreshCatalog() async throws {
    catalogGeneration += 1
    let generation = catalogGeneration
    status = .loading
    do {
      let response = try await transport.get(Self.indexURL)
      let text = try responseText(response)
      let entries = AutoEQCatalogParser.parseIndexMarkdown(text)
      guard !entries.isEmpty else { throw ProfileRepositoryError.invalidCatalog }
      try Task.checkCancellation()
      // An older caller can finish or fail, but cannot publish over a newer catalog operation.
      guard catalogGeneration == generation else { throw CancellationError() }
      try files.writeCatalog(entries)
      catalog = entries
      diskCatalog = .present(now())
      rebuildIndex()
      status = .ready
    } catch {
      if catalogGeneration == generation { status = .failed(error) }
      throw error
    }
  }

  public func search(
    query: String, limit: Int = 50, eligibleIDs: Set<String>? = nil
  ) -> AutoEQSearchResult {
    searchIndex.search(query: query, limit: limit, eligibleIDs: eligibleIDs)
  }

  /// Name-sorted metadata for the empty-query favorites view, without applying search's result cap.
  public func entries(eligibleIDs: Set<String>? = nil) -> [AutoEQCatalogEntry] {
    searchIndex.filteredEntries(eligibleIDs: eligibleIDs)
  }

  public func resolveProfile(for id: String) async throws -> AutoEQProfile {
    try ProfileFileStore.validateIdentifier(id)
    if let loaded = cache.profile(for: id) { return loaded }
    guard let entry = catalog.first(where: { $0.id == id }) else {
      throw ProfileRepositoryError.unknownProfile(id)
    }
    if let text = try files.readFetchedText(id: id) {
      let result = try parseFetched(text, entry: entry)
      publish(result)
      return result.profile
    }
    let response = try await transport.get(try Self.profileURL(for: entry))
    let text = try responseText(response)
    let result = try parseFetched(text, entry: entry)
    try Task.checkCancellation()
    try files.writeFetchedText(text, id: id)
    publish(result)
    return result.profile
  }

  public func importProfile(from url: URL, name: String) throws -> AutoEQProfile {
    guard url.isFileURL else {
      throw ProfileRepositoryError.invalidImportURL(url.absoluteString)
    }
    let id = makeImportedID()
    try ProfileFileStore.validateIdentifier(id)
    let text = try files.readImportText(from: url)
    let result = try ParametricEQTextParser.parse(text: text, name: name, source: .imported, id: id)
    try files.writeImportedProfile(text: text, name: name, id: id)
    publish(result)
    importedEntries.removeAll { $0.id == id }
    importedEntries.append(importedEntry(result.profile))
    rebuildIndex()
    return result.profile
  }

  public func deleteImportedProfile(id: String) throws {
    try ProfileFileStore.validateIdentifier(id)
    guard let profile = cache.profile(for: id), profile.source == .imported else {
      throw ProfileRepositoryError.notImported(id)
    }
    try files.removeImportedProfile(id: id)
    cache.remove(id: id)
    cacheRevision += 1
    parseDiagnostics[id] = nil
    importedEntries.removeAll { $0.id == id }
    rebuildIndex()
  }

  public static func profileURL(for entry: AutoEQCatalogEntry) throws -> URL {
    let path = entry.relativePath
    let parts = path.components(separatedBy: "/")
    guard !path.hasPrefix("/"), !path.contains("\\"),
      URLComponents(string: path)?.scheme == nil,
      !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ProfileRepositoryError.invalidRelativePath(path) }
    var url = profileBaseURL
    for part in parts { url.appendPathComponent(part, isDirectory: true) }
    url.appendPathComponent("\(parts[parts.count - 1]) ParametricEQ.txt", isDirectory: false)
    return url
  }

  /// Local restoration and refresh share one decoded catalog, not repeated disk reads.
  private func loadCachedCatalog() throws -> Date? {
    switch diskCatalog {
    case .present(let date): return date
    case .absent: return nil
    case .unread:
      guard let cached = try files.readCatalog() else {
        diskCatalog = .absent
        return nil
      }
      catalog = cached.entries
      diskCatalog = .present(cached.modifiedAt)
      rebuildIndex()
      status = .ready
      return cached.modifiedAt
    }
  }

  private func responseText(_ response: ProfileHTTPResponse) throws -> String {
    guard response.statusCode == 200 else {
      throw ProfileRepositoryError.httpStatus(response.statusCode)
    }
    guard let text = String(data: response.data, encoding: .utf8) else {
      throw ProfileRepositoryError.invalidUTF8
    }
    return text
  }

  private func parseFetched(_ text: String, entry: AutoEQCatalogEntry) throws -> ParsedAutoEQProfile
  {
    let parsed = try ParametricEQTextParser.parse(
      text: text, name: entry.name, source: .fetched, id: entry.id)
    return ParsedAutoEQProfile(
      profile: AutoEQProfile(
        id: entry.id, name: entry.name, source: .fetched, preampDB: parsed.profile.preampDB,
        filters: parsed.profile.filters, measuredBy: entry.measuredBy, optimizedSampleRate: 48000),
      diagnostics: parsed.diagnostics)
  }

  private func publish(_ parsed: ParsedAutoEQProfile) {
    cache.store(parsed.profile)
    parseDiagnostics[parsed.profile.id] = parsed.diagnostics
    cacheRevision += 1
  }

  private func importedEntry(_ profile: AutoEQProfile) -> AutoEQCatalogEntry {
    AutoEQCatalogEntry(id: profile.id, name: profile.name, measuredBy: "Imported", relativePath: "")
  }

  private func rebuildIndex() {
    searchIndex = AutoEQSearchIndex(entries: catalog + importedEntries)
  }
}
