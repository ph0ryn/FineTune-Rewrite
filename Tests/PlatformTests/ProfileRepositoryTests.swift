import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

// Independently authored unit coverage for the new profile format/storage boundary (MIT).
@Suite("AutoEQ profile format contracts")
struct ProfileParsingTests {
  @Test(
    "Supported APO filter aliases preserve parameter units",
    arguments: [
      ("PK", AutoEQFilter.FilterType.peaking), ("PEQ", .peaking),
      ("LS", .lowShelf), ("LSC", .lowShelf), ("HS", .highShelf), ("HSC", .highShelf),
    ])
  func aliases(alias: String, expectedType: AutoEQFilter.FilterType) throws {
    let result = try ParametricEQTextParser.parse(
      text: "Preamp: -6.25 dB\nFilter 1: ON \(alias) Fc 1234 Hz Gain -2.5 dB Q 1.25",
      name: "Unit Headphone", source: .imported, id: "stable-id")
    #expect(result.profile.id == "stable-id")
    #expect(result.profile.preampDB == -6.25)
    #expect(
      result.profile.filters == [
        AutoEQFilter(type: expectedType, frequency: 1234, gainDB: -2.5, q: 1.25)
      ])
    #expect(result.diagnostics.isEmpty)
  }

  @Test("Disabled or wholly invalid text never produces a successful empty profile")
  func emptyProfileFails() {
    #expect(throws: ProfileRepositoryError.noValidFilters) {
      try ParametricEQTextParser.parse(
        text: "Filter 1: OFF PK Fc 100 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc -1 Hz Gain 3 dB Q 1",
        name: "Invalid", source: .imported, id: "invalid")
    }
  }

  @Test("Partial invalid input and truncation are observable, not silent fallback")
  func diagnosticsAndLimit() throws {
    let lines = (1...12).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1 dB Q 1" }
    let result = try ParametricEQTextParser.parse(
      text: (["Preamp: malformed", "Filter 0: ON PK Fc 0 Hz Gain 1 dB Q 1"] + lines)
        .joined(separator: "\n"),
      name: "Partial", source: .fetched, id: "partial")
    #expect(result.profile.preampDB == 0)
    #expect(result.profile.filters.count == 10)
    #expect(result.profile.filters.last?.frequency == 1000)
    #expect(result.diagnostics.count == 3)
  }

  @Test("Catalog parentheses, decoding and source priority retain the fixed source meaning")
  func catalogContracts() {
    let entries = AutoEQCatalogParser.parseIndexMarkdown(
      """
      # Fixture index
      - [Unit Phone (Closed)](./Rtings/over-ear/Unit%20Phone%20(Closed)) by Rtings on Rig
      - [Unit Phone (Closed)](./oratory1990/over-ear/Unit%20Phone%20(Closed)) by oratory1990
      - [Another](./crinacle/in-ear/Another) by crinacle
      """)
    #expect(entries.count == 2)
    let preferred = entries.first { $0.name == "Unit Phone (Closed)" }
    #expect(preferred?.id == "unit-phone-closed")
    #expect(preferred?.measuredBy == "oratory1990")
    #expect(preferred?.relativePath == "oratory1990/over-ear/Unit Phone (Closed)")
  }
}

@Suite("AutoEQ isolated profile file store")
@MainActor
struct ProfileFileStoreTests {
  private func uniqueDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTuneProfiles-\(UUID().uuidString)", isDirectory: true)
  }

  @Test("Constructing and reading absent profile storage performs no creation")
  func constructionDoesNotCreateStorage() throws {
    let directory = uniqueDirectory()
    let store = try ProfileFileStore(directory: directory)
    #expect(try store.readCatalog() == nil)
    #expect(try store.readImportedProfiles().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test("Imported text/name reload with the same persisted identity")
  func importReadback() throws {
    let directory = uniqueDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ProfileFileStore(directory: directory)
    let text = "Preamp: -2 dB\nFilter 1: ON PK Fc 500 Hz Gain 3 dB Q 0.7"
    try store.writeImportedProfile(text: text, name: "Unit Display Name", id: "fixed-import")
    let reloaded = try ProfileFileStore(directory: directory).readImportedProfiles()
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.id == "fixed-import")
    #expect(reloaded.first?.name == "Unit Display Name")
    #expect(reloaded.first?.text == text)
    #expect(
      try String(
        contentsOf: directory.appendingPathComponent("AutoEQ/fixed-import.txt"), encoding: .utf8)
        == text)
  }

  @Test("Cache identifiers cannot escape the explicit directory")
  func escapingIdentifierFails() throws {
    let directory = uniqueDirectory()
    let store = try ProfileFileStore(directory: directory)
    #expect(throws: ProfileRepositoryError.invalidIdentifier("../escape")) {
      try store.writeFetchedText("untrusted", id: "../escape")
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }
}

private enum ProfileTestFailure: Error, Equatable { case io, unexpectedRequest }

private actor ProfileHTTPStub: ProfileHTTPTransport {
  private var responses: [ProfileHTTPResponse]
  private(set) var requestedURLs: [URL] = []

  init(_ responses: [ProfileHTTPResponse] = []) { self.responses = responses }

  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    requestedURLs.append(url)
    guard !responses.isEmpty else { throw ProfileTestFailure.unexpectedRequest }
    return responses.removeFirst()
  }
}

@MainActor
private final class ProfileFilesStub: ProfileFileStoring {
  enum FailurePoint { case readCatalog, writeFetched, writeImport, removeImport }
  var failure: FailurePoint?
  var cachedCatalog: CachedAutoEQCatalog?
  var fetched: [String: String] = [:]
  var imported: [ImportedProfileText] = []
  var importText = "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 1"
  var reads = 0
  var catalogWrites = 0

  func readCatalog() throws -> CachedAutoEQCatalog? {
    reads += 1
    if failure == .readCatalog { throw ProfileTestFailure.io }
    return cachedCatalog
  }
  func writeCatalog(_ entries: [AutoEQCatalogEntry]) throws {
    catalogWrites += 1
    cachedCatalog = CachedAutoEQCatalog(entries: entries, modifiedAt: Date())
  }
  func readFetchedText(id: String) throws -> String? {
    reads += 1
    return fetched[id]
  }
  func writeFetchedText(_ text: String, id: String) throws {
    if failure == .writeFetched { throw ProfileTestFailure.io }
    fetched[id] = text
  }
  func readImportedProfiles() throws -> [ImportedProfileText] {
    reads += 1
    return imported
  }
  func readImportText(from url: URL) throws -> String {
    reads += 1
    return importText
  }
  func writeImportedProfile(text: String, name: String, id: String) throws {
    if failure == .writeImport { throw ProfileTestFailure.io }
    imported.append(ImportedProfileText(id: id, name: name, text: text))
  }
  func removeImportedProfile(id: String) throws {
    if failure == .removeImport { throw ProfileTestFailure.io }
    imported.removeAll { $0.id == id }
  }
}

@Suite("AutoEQ repository cache and transport contracts")
@MainActor
struct ProfileRepositoryTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let text = "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 1"
  private var entry: AutoEQCatalogEntry {
    AutoEQCatalogEntry(
      id: "unit-phone-closed", name: "Unit Phone (Closed)", measuredBy: "oratory1990",
      relativePath: "oratory1990/over-ear/Unit Phone (Closed)")
  }

  private func files(age: TimeInterval = 0, entries: [AutoEQCatalogEntry]? = nil)
    -> ProfileFilesStub
  {
    let result = ProfileFilesStub()
    result.cachedCatalog = CachedAutoEQCatalog(
      entries: entries ?? [entry], modifiedAt: now.addingTimeInterval(-age))
    return result
  }

  private func repository(
    cache: AutoEQProfileCache = AutoEQProfileCache(), files: ProfileFilesStub,
    http: ProfileHTTPStub = ProfileHTTPStub()
  ) -> AutoEQProfileRepository {
    AutoEQProfileRepository(
      cache: cache, files: files, transport: http, now: { now }, makeImportedID: { "import-uuid" })
  }

  @Test("Repository construction starts neither file nor HTTP work")
  func constructionIsInert() async {
    let files = files()
    let http = ProfileHTTPStub()
    _ = repository(files: files, http: http)
    #expect(files.reads == 0)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test("A shared memory profile is resolved without file or HTTP fallback")
  func memoryIsTheSingleLoadedProfileStore() async throws {
    let profile = AutoEQProfile(
      id: "memory", name: "Loaded", source: .imported, preampDB: 0,
      filters: [AutoEQFilter(type: .peaking, frequency: 100, gainDB: 1, q: 1)])
    let cache = AutoEQProfileCache(profiles: [profile])
    let files = files()
    let http = ProfileHTTPStub()
    let repo = repository(cache: cache, files: files, http: http)
    #expect(try await repo.resolveProfile(for: "memory") == profile)
    #expect(files.reads == 0)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test("The exact seven-day cache boundary is fresh")
  func ttlBoundaryIsFresh() async throws {
    let files = files(age: 7 * 24 * 3600)
    let http = ProfileHTTPStub()
    let repo = repository(files: files, http: http)
    try await repo.loadCatalog()
    #expect(repo.catalog == [entry])
    #expect(repo.catalogState == .ready)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test("Stale refresh failure retains good entries and explicitly reports failure")
  func staleFailureRetainsCatalog() async {
    let files = files(age: 7 * 24 * 3600 + 1)
    let http = ProfileHTTPStub([ProfileHTTPResponse(data: Data(), statusCode: 503)])
    let repo = repository(files: files, http: http)
    await #expect(throws: ProfileRepositoryError.httpStatus(503)) { try await repo.loadCatalog() }
    #expect(repo.catalog == [entry])
    #expect(repo.catalogState == .failed)
    #expect(repo.catalogError != nil)
    #expect(files.catalogWrites == 0)
  }

  @Test("Disk profile cache loads offline into the same injected memory cache")
  func fetchedDiskCacheIsOffline() async throws {
    let files = files()
    files.fetched[entry.id] = text
    let cache = AutoEQProfileCache()
    let http = ProfileHTTPStub()
    let repo = repository(cache: cache, files: files, http: http)
    try await repo.loadCatalog()
    let profile = try await repo.resolveProfile(for: entry.id)
    #expect(profile.measuredBy == entry.measuredBy)
    #expect(profile.optimizedSampleRate == 48000)
    #expect(cache.profile(for: entry.id) == profile)
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test("A fetched profile uses the fixed source and persists before becoming available")
  func fixedSourceAndPersistedFetch() async throws {
    let files = files()
    let cache = AutoEQProfileCache()
    let http = ProfileHTTPStub([ProfileHTTPResponse(data: Data(text.utf8), statusCode: 200)])
    let repo = repository(cache: cache, files: files, http: http)
    try await repo.loadCatalog()
    let profile = try await repo.resolveProfile(for: entry.id)
    let urls = await http.requestedURLs
    #expect(urls.count == 1)
    #expect(urls.first?.host == "raw.githubusercontent.com")
    #expect(
      urls.first?.path
        == "/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Unit Phone (Closed)/Unit Phone (Closed) ParametricEQ.txt"
    )
    #expect(urls.first?.query == nil)
    #expect(urls.first?.fragment == nil)
    #expect(files.fetched[entry.id] == text)
    #expect(cache.profile(for: entry.id) == profile)
  }

  @Test(
    "HTTP, encoding and parse failures never populate a success cache",
    arguments: [
      (404, Data(), ProfileRepositoryError.httpStatus(404)),
      (200, Data([0xFF]), .invalidUTF8),
      (200, Data("Filter 1: OFF PK Fc 100 Hz Gain 2 dB Q 1".utf8), .noValidFilters),
    ])
  func invalidFetchIsNotSuccess(status: Int, body: Data, expected: ProfileRepositoryError)
    async throws
  {
    let files = files()
    let cache = AutoEQProfileCache()
    let http = ProfileHTTPStub([ProfileHTTPResponse(data: body, statusCode: status)])
    let repo = repository(cache: cache, files: files, http: http)
    try await repo.loadCatalog()
    await #expect(throws: expected) { try await repo.resolveProfile(for: entry.id) }
    #expect(cache.profile(for: entry.id) == nil)
    #expect(files.fetched.isEmpty)
  }

  @Test("Failed profile persistence cannot publish a memory-only success")
  func fetchedWriteFailureKeepsCacheAbsent() async throws {
    let files = files()
    files.failure = .writeFetched
    let cache = AutoEQProfileCache()
    let http = ProfileHTTPStub([ProfileHTTPResponse(data: Data(text.utf8), statusCode: 200)])
    let repo = repository(cache: cache, files: files, http: http)
    try await repo.loadCatalog()
    await #expect(throws: ProfileTestFailure.io) { try await repo.resolveProfile(for: entry.id) }
    #expect(cache.profile(for: entry.id) == nil)
    #expect(files.fetched.isEmpty)
  }

  @Test(
    "Unsafe catalog paths are rejected before making a request",
    arguments: [
      "/outside", "../outside", "oratory1990/../outside", "https://other.example/path", "a//b",
    ])
  func unsafePathNeverRequests(path: String) async throws {
    let bad = AutoEQCatalogEntry(
      id: "safe-id", name: "Bad", measuredBy: "source", relativePath: path)
    let files = files(entries: [bad])
    let http = ProfileHTTPStub()
    let repo = repository(files: files, http: http)
    try await repo.loadCatalog()
    await #expect(throws: ProfileRepositoryError.invalidRelativePath(path)) {
      try await repo.resolveProfile(for: bad.id)
    }
    #expect(await http.requestedURLs.isEmpty)
  }

  @Test("Import/delete failures keep the last committed cache and disk view")
  func importAndDeleteCommitOrder() throws {
    let files = files()
    let cache = AutoEQProfileCache()
    let repo = repository(cache: cache, files: files)
    let url = URL(fileURLWithPath: "/explicitly-selected-unit-input.txt")
    let imported = try repo.importProfile(from: url, name: "Imported Unit")
    #expect(imported.id == "import-uuid")
    #expect(cache.profile(for: imported.id) == imported)
    #expect(files.imported.first?.text == text)
    files.failure = .removeImport
    #expect(throws: ProfileTestFailure.io) { try repo.deleteImportedProfile(id: imported.id) }
    #expect(cache.profile(for: imported.id) == imported)
    #expect(files.imported.count == 1)
    files.failure = nil
    try repo.deleteImportedProfile(id: imported.id)
    #expect(cache.profile(for: imported.id) == nil)
    #expect(files.imported.isEmpty)
  }

  @Test("Failed import never appears as a usable cached or searchable profile")
  func importWriteFailureIsNotSuccess() {
    let files = files()
    files.failure = .writeImport
    let cache = AutoEQProfileCache()
    let repo = repository(cache: cache, files: files)
    #expect(throws: ProfileTestFailure.io) {
      try repo.importProfile(
        from: URL(fileURLWithPath: "/explicit-unit.txt"), name: "Failed Import")
    }
    #expect(cache.profile(for: "import-uuid") == nil)
    #expect(repo.search(query: "Failed").entries.isEmpty)
    #expect(files.imported.isEmpty)
  }

  @Test("Unreadable catalog is not silently replaced by a network fallback")
  func unreadableCacheIsObservable() async {
    let files = files()
    files.failure = .readCatalog
    let http = ProfileHTTPStub()
    let repo = repository(files: files, http: http)
    await #expect(throws: ProfileTestFailure.io) { try await repo.loadCatalog() }
    #expect(repo.catalogState == .failed)
    #expect(repo.catalogError != nil)
    #expect(await http.requestedURLs.isEmpty)
    #expect(files.catalogWrites == 0)
  }

  @Test("Favorites filter the candidate set before the unchanged search limit")
  func favoritesBeforeSearchLimit() async throws {
    let entries = (0...60).map {
      AutoEQCatalogEntry(
        id: "u\($0)", name: "Unit \($0)", measuredBy: "source", relativePath: "source/Unit \($0)")
    }
    let repo = repository(files: files(entries: entries))
    try await repo.loadCatalog()
    #expect(!repo.search(query: "Unit").entries.contains { $0.id == "u60" })
    #expect(repo.search(query: "Unit", eligibleIDs: ["u60"]).entries.map(\.id) == ["u60"])
    #expect(repo.entries(eligibleIDs: ["u60"]).map(\.id) == ["u60"])
    #expect(repo.search(query: "").entries.isEmpty)
  }

  @Test("Selected fetched disk cache is restored synchronously without awaiting HTTP")
  func selectedFetchedCacheIsLocalPreparation() async throws {
    let files = files()
    files.fetched[entry.id] = text
    let cache = AutoEQProfileCache()
    let http = ProfileHTTPStub()
    let repo = repository(cache: cache, files: files, http: http)
    let loadedIDs = try repo.loadLocalProfiles(selectedProfileIDs: [entry.id])
    #expect(loadedIDs.contains(entry.id))
    #expect(cache.profile(for: entry.id)?.name == entry.name)
    #expect(cache.profile(for: entry.id)?.measuredBy == entry.measuredBy)
    #expect(await http.requestedURLs.isEmpty)
  }
}
