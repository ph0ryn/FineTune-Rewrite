import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@MainActor
private final class URLCommandSinkSpy: AudioCommandHandling {
  private(set) var commands: [AudioCommand] = []
  func perform(_ command: AudioCommand) { commands.append(command) }
}

@Suite("App composition: URLAutomationController adapter")
@MainActor
struct URLAutomationControllerTests {
  @Test("A URL dispatches normalized commands synchronously to the required common handler")
  func dispatchIsImmediateAndOrdered() throws {
    let sink = URLCommandSinkSpy()
    let controller = URLAutomationController(commandHandler: sink)
    controller.handleURL(
      try #require(URL(string: "finetune://set-volumes?app=Com.A&volume=25&app=Com.B&volume=100")))
    controller.handleURL(try #require(URL(string: "finetune://toggle-mute?app=Com.A")))
    #expect(
      sink.commands == [
        .setGain(identifier: "Com.A", gain: 0.25), .setGain(identifier: "Com.B", gain: 1),
        .toggleMuted(identifier: "Com.A"),
      ])
    #expect(controller.lastPlan?.diagnostics.isEmpty == true)
  }

  @Test("Rejected URLs are observable and cannot dispatch a reset-all fallback")
  func rejectionIsObservable() throws {
    let sink = URLCommandSinkSpy()
    let controller = URLAutomationController(commandHandler: sink)
    controller.handleURL(try #require(URL(string: "finetune://reset?app")))
    #expect(sink.commands.isEmpty)
    #expect(controller.lastPlan?.diagnostics.isEmpty == false)
  }
}

@MainActor
private final class ProfilePreferenceReadStub: AutoEQPreferencesReading {
  var selections: [String: AutoEQSelection] = [:]
  var favoriteAutoEQProfileIDs: Set<String> = []
  var autoEQPreampEnabled = true
  func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? { selections[deviceUID] }
}

private struct ProfileRequestTimeout: Error, CustomStringConvertible {
  let target: Int
  let timeout: Duration
  var description: String {
    "Timed out after \(timeout) waiting for \(target) profile HTTP request(s)"
  }
}

private actor AppProfileHTTPGate: ProfileHTTPTransport {
  private struct Waiter {
    let count: Int
    let continuation: CheckedContinuation<Void, any Error>
    let timeout: Task<Void, Never>
  }

  private struct Reply {
    let id: UUID
    var continuation: CheckedContinuation<ProfileHTTPResponse, any Error>?
  }

  private static let requestTimeout = Duration.seconds(5)
  private(set) var requestedURLs: [URL] = []
  private var replies: [Reply] = []
  private var requestWaiters: [UUID: Waiter] = [:]

  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    requestedURLs.append(url)
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        replies.append(Reply(id: id, continuation: continuation))
        resumeSatisfiedWaiters()
      }
    } onCancel: {
      Task { await self.cancelReply(id) }
    }
  }

  func waitForRequest(count: Int = 1) async throws {
    if requestedURLs.count >= count { return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard requestedURLs.count < count else {
          continuation.resume()
          return
        }
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeout = Task<Void, Never> { [weak self] in
          try? await Task.sleep(for: Self.requestTimeout)
          guard !Task.isCancelled else { return }
          await self?.timeoutWaiter(id)
        }
        requestWaiters[id] = Waiter(count: count, continuation: continuation, timeout: timeout)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  func respond(_ response: ProfileHTTPResponse, at index: Int = 0) {
    precondition(replies.indices.contains(index))
    guard let continuation = replies[index].continuation else { return }
    replies[index].continuation = nil
    continuation.resume(returning: response)
  }

  private func resumeSatisfiedWaiters() {
    for id in requestWaiters.filter({ $0.value.count <= requestedURLs.count }).keys {
      guard let waiter = requestWaiters.removeValue(forKey: id) else { continue }
      waiter.timeout.cancel()
      waiter.continuation.resume()
    }
  }

  private func timeoutWaiter(_ id: UUID) {
    guard let waiter = requestWaiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(
      throwing: ProfileRequestTimeout(target: waiter.count, timeout: Self.requestTimeout))
  }

  private func cancelWaiter(_ id: UUID) {
    guard let waiter = requestWaiters.removeValue(forKey: id) else { return }
    waiter.timeout.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func cancelReply(_ id: UUID) {
    guard let index = replies.firstIndex(where: { $0.id == id }),
      let continuation = replies[index].continuation
    else { return }
    replies[index].continuation = nil
    continuation.resume(throwing: CancellationError())
  }
}

@MainActor
private struct ProfileAutomationFixture {
  let directory: URL
  let files: ProfileFileStore
  let cache: AutoEQProfileCache
  let repository: AutoEQProfileRepository
  let preferences: ProfilePreferenceReadStub
  let commands: URLCommandSinkSpy
  let http: AppProfileHTTPGate
  let automation: AutoEQAutomation

  func cleanUp() {
    automation.stop()
    if FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

@Suite(
  "App composition: AutoEQAutomation orchestration and token cancellation", .serialized,
  .timeLimit(.minutes(1)))
@MainActor
struct AutoEQAutomationTests {
  private let text = "Preamp: -3 dB\nFilter 1: ON PK Fc 500 Hz Gain 2 dB Q 1"

  private func profile(_ id: String) -> AutoEQProfile {
    AutoEQProfile(
      id: id, name: "Profile \(id)", source: .fetched, preampDB: -3,
      filters: [AutoEQFilter(type: .peaking, frequency: 500, gainDB: 2, q: 1)], measuredBy: "source"
    )
  }

  private func fixture(
    prepareCatalog: Bool = true, cachedProfiles: [AutoEQProfile] = [],
    connectedDeviceUIDs: @escaping @MainActor () -> [String] = { ["origin"] }
  ) async throws -> ProfileAutomationFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTuneProfileAutomation-\(UUID().uuidString)", isDirectory: true)
    let files = try ProfileFileStore(directory: directory)
    let cache = AutoEQProfileCache(profiles: cachedProfiles)
    let http = AppProfileHTTPGate()
    let repository = AutoEQProfileRepository(
      cache: cache, files: files, transport: http, makeImportedID: { "import-uuid" })
    if prepareCatalog {
      try files.writeCatalog(
        ["A", "B"].map {
          AutoEQCatalogEntry(
            id: $0, name: "Profile \($0)", measuredBy: "source",
            relativePath: "source/Profile \($0)")
        })
      try await repository.loadCatalog()
    }
    let preferences = ProfilePreferenceReadStub()
    let commands = URLCommandSinkSpy()
    let automation = AutoEQAutomation(
      repository: repository, preferences: preferences, commands: commands,
      connectedDeviceUIDs: connectedDeviceUIDs)
    return ProfileAutomationFixture(
      directory: directory, files: files, cache: cache, repository: repository,
      preferences: preferences, commands: commands, http: http, automation: automation)
  }

  @Test("Constructing the consumer neither calls its device provider nor starts I/O")
  func constructionIsInert() async throws {
    var providerCalls = 0
    let fixture = try await fixture(
      prepareCatalog: false,
      connectedDeviceUIDs: {
        providerCalls += 1
        return ["origin"]
      })
    defer { fixture.cleanUp() }
    #expect(providerCalls == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    #expect(await fixture.http.requestedURLs.isEmpty)
    #expect(fixture.commands.commands.isEmpty)
  }

  @Test("Presentation and favorites are local reads of the authoritative ports")
  func readAndSearchAreLocal() async throws {
    let fixture = try await fixture(cachedProfiles: [profile("A")])
    defer { fixture.cleanUp() }
    let saved = AutoEQSelection(profileID: "A", isEnabled: false)
    fixture.preferences.selections["origin"] = saved
    fixture.preferences.favoriteAutoEQProfileIDs = ["A"]
    fixture.preferences.autoEQPreampEnabled = false
    let presentation = fixture.automation.presentation(for: "origin")
    #expect(presentation.selection == saved)
    #expect(presentation.profileName == "Profile A")
    #expect(!presentation.isMissing)
    #expect(!presentation.isResolving)
    #expect(!presentation.preampEnabled)
    #expect(fixture.automation.search(query: "", favoritesOnly: true).entries.map(\.id) == ["A"])
    #expect(await fixture.http.requestedURLs.isEmpty)
  }

  @Test(
    "The production selected profile exposes its measured or imported source",
    arguments: [AutoEQSource.fetched, .imported])
  func mixerSelectedProfileRetainsSource(source: AutoEQSource) async throws {
    let selected = AutoEQProfile(
      id: "selected", name: "Selected headphones", source: source, preampDB: -3,
      filters: [AutoEQFilter(type: .peaking, frequency: 500, gainDB: 2, q: 1)],
      measuredBy: source == .imported ? nil : "Measurement source")
    let fixture = try await fixture(cachedProfiles: [selected])
    defer { fixture.cleanUp() }
    fixture.preferences.selections["origin"] = AutoEQSelection(
      profileID: selected.id, isEnabled: false)
    let current = fixture.automation.makeMixerInterface().read("origin")
    #expect(current.profileName == selected.name)
    #expect(current.profileDetail == (source == .imported ? "Imported" : "Measurement source"))
    #expect(current.selection?.isEnabled == false)
    #expect(await fixture.http.requestedURLs.isEmpty)
    #expect(fixture.commands.commands.isEmpty)
  }

  @Test("Required UI requests use the common commands and do not invent saved state")
  func requiredCallbacksShareTheCommandBoundary() async throws {
    let fixture = try await fixture(cachedProfiles: [profile("A")])
    defer { fixture.cleanUp() }
    let saved = AutoEQSelection(profileID: "A", isEnabled: false)
    fixture.preferences.selections["origin"] = saved
    let interface = fixture.automation.makeMixerInterface()
    interface.select("origin", AutoEQSelection(profileID: "A", isEnabled: true))
    interface.setFavorite("A", false)
    interface.setPreampEnabled(false)
    #expect(
      fixture.commands.commands == [
        .setAutoEQSelection(
          deviceUID: "origin", selection: AutoEQSelection(profileID: "A", isEnabled: true)),
        .setAutoEQFavorite(profileID: "A", favorite: false), .setAutoEQPreampEnabled(false),
      ])
    #expect(interface.read("origin").selection == saved)
  }

  @Test("Import persists and selects for the originating UID, not the current device")
  func importedProfileKeepsItsOrigin() async throws {
    let fixture = try await fixture(connectedDeviceUIDs: { ["a-different-device"] })
    defer { fixture.cleanUp() }
    let input = fixture.directory.appendingPathComponent("selected-input.txt")
    try text.write(to: input, atomically: true, encoding: .utf8)
    let imported = try fixture.automation.importProfile(
      forDeviceUID: "origin", from: input, name: "Imported"
    ).get()
    #expect(fixture.cache.profile(for: imported.id) == imported)
    #expect(
      fixture.commands.commands == [
        .profileAvailabilityChanged(profileID: imported.id),
        .setAutoEQSelection(
          deviceUID: "origin", selection: AutoEQSelection(profileID: imported.id, isEnabled: true)),
      ])
  }

  @Test("Failed import is observable and does not replace the saved selection")
  func failedImportRetainsTheWish() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let saved = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = saved
    let input = fixture.directory.appendingPathComponent("invalid-input.txt")
    try "No supported filters".write(to: input, atomically: true, encoding: .utf8)
    let result = fixture.automation.importProfile(
      forDeviceUID: "origin", from: input, name: "Invalid")
    #expect(throws: ProfileRepositoryError.noValidFilters) { try result.get() }
    #expect(fixture.preferences.selections["origin"] == saved)
    #expect(fixture.commands.commands.isEmpty)
    #expect(fixture.automation.presentation(for: "origin").selectionError != nil)
  }

  @Test("A late A response cannot resave A after a newer B selection")
  func lateProfileCannotOverwriteNewerSelection() async throws {
    let fixture = try await fixture(cachedProfiles: [profile("B")])
    defer { fixture.cleanUp() }
    let selectedA = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = selectedA
    let first = try #require(fixture.automation.select(selectedA, forDeviceUID: "origin"))
    try await fixture.http.waitForRequest()
    let selectedB = AutoEQSelection(profileID: "B", isEnabled: true)
    fixture.preferences.selections["origin"] = selectedB
    fixture.automation.select(selectedB, forDeviceUID: "origin")
    await fixture.http.respond(ProfileHTTPResponse(data: Data(text.utf8), statusCode: 200))
    await first.value
    #expect(fixture.automation.presentation(for: "origin").selection == selectedB)
    #expect(fixture.cache.profile(for: "A") == nil)
    #expect(
      fixture.commands.commands == [
        .setAutoEQSelection(deviceUID: "origin", selection: selectedA),
        .setAutoEQSelection(deviceUID: "origin", selection: selectedB),
      ])
  }

  @Test("Disabling during acquisition preserves the same disabled profile wish")
  func lateProfileCannotReenableSelection() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let enabled = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = enabled
    let first = try #require(fixture.automation.select(enabled, forDeviceUID: "origin"))
    try await fixture.http.waitForRequest()
    let disabled = AutoEQSelection(profileID: "A", isEnabled: false)
    fixture.preferences.selections["origin"] = disabled
    fixture.automation.select(disabled, forDeviceUID: "origin")
    await fixture.http.respond(ProfileHTTPResponse(data: Data(text.utf8), statusCode: 200))
    await first.value
    #expect(fixture.automation.presentation(for: "origin").selection == disabled)
    #expect(fixture.cache.profile(for: "A") == nil)
    #expect(
      fixture.commands.commands.last
        == .setAutoEQSelection(deviceUID: "origin", selection: disabled))
  }

  @Test("Lifecycle stop cancels acquisition and makes retained request callbacks inert")
  func stopPreventsLateEffects() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let selected = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = selected
    let interface = fixture.automation.makeMixerInterface()
    let first = try #require(fixture.automation.select(selected, forDeviceUID: "origin"))
    try await fixture.http.waitForRequest()
    fixture.automation.stop()
    interface.select("origin", nil)
    await fixture.http.respond(ProfileHTTPResponse(data: Data(text.utf8), statusCode: 200))
    await first.value
    #expect(fixture.cache.profile(for: "A") == nil)
    #expect(
      fixture.commands.commands == [.setAutoEQSelection(deviceUID: "origin", selection: selected)])
    #expect(!interface.read("origin").isResolving)
  }

  @Test("Profile HTTP failure keeps the saved wish and exposes a selection error")
  func acquisitionFailureIsNotMissingSuccess() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let selected = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = selected
    let task = try #require(fixture.automation.select(selected, forDeviceUID: "origin"))
    try await fixture.http.waitForRequest()
    await fixture.http.respond(ProfileHTTPResponse(data: Data(), statusCode: 503))
    await task.value
    let presentation = fixture.automation.presentation(for: "origin")
    #expect(presentation.selection == selected)
    #expect(presentation.isMissing)
    #expect(!presentation.isResolving)
    #expect(presentation.selectionError?.contains("503") == true)
  }

  @Test("Catalog failure is distinct from an empty local search")
  func catalogFailureIsObservable() async throws {
    let fixture = try await fixture(prepareCatalog: false)
    defer { fixture.cleanUp() }
    let task = fixture.automation.start()
    try await fixture.http.waitForRequest()
    await fixture.http.respond(ProfileHTTPResponse(data: Data(), statusCode: 503))
    await task?.value
    guard case .failed(let message) = fixture.automation.presentation(for: "origin").catalogState
    else {
      Issue.record("Expected an explicit failed catalog presentation")
      return
    }
    #expect(message.contains("503"))
    #expect(fixture.automation.search(query: "Profile", favoritesOnly: false).entries.isEmpty)
  }

  @Test(
    "An old canceled catalog request cannot demote a successful restarted service",
    arguments: [200, 503])
  func canceledCatalogCannotOverwriteRestartedReady(oldStatus: Int) async throws {
    let fixture = try await fixture(prepareCatalog: false)
    defer { fixture.cleanUp() }
    let first = fixture.automation.start()
    try await fixture.http.waitForRequest()
    fixture.automation.stop()
    let restarted = fixture.automation.start()
    try await fixture.http.waitForRequest(count: 2)
    let freshIndex = "- [Newest B](./oratory1990/over-ear/Newest%20B) by oratory1990"
    await fixture.http.respond(
      ProfileHTTPResponse(data: Data(freshIndex.utf8), statusCode: 200), at: 1)
    await restarted?.value
    #expect(fixture.repository.catalogState == .ready)
    let oldIndex = "- [Old A](./oratory1990/over-ear/Old%20A) by oratory1990"
    await fixture.http.respond(
      ProfileHTTPResponse(data: Data(oldIndex.utf8), statusCode: oldStatus))
    await first?.value
    #expect(fixture.repository.catalog.map(\.id) == ["newest-b"])
    #expect(fixture.repository.catalogState == .ready)
    #expect(fixture.repository.catalogError == nil)
    #expect(fixture.automation.presentation(for: "origin").catalogState == .ready)
  }
}
