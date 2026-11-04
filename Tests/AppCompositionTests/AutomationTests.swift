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

// Adapter coverage only; actual saved/runtime effects are tested through the common Control handler.
@Suite("App URL command consumer")
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

private actor AppProfileHTTPGate: ProfileHTTPTransport {
  private(set) var requestedURLs: [URL] = []
  private var replies: [CheckedContinuation<ProfileHTTPResponse, any Error>] = []
  private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func get(_ url: URL) async throws -> ProfileHTTPResponse {
    requestedURLs.append(url)
    return try await withCheckedThrowingContinuation { continuation in
      replies.append(continuation)
      let ready = requestWaiters.filter { $0.count <= requestedURLs.count }
      requestWaiters.removeAll { $0.count <= requestedURLs.count }
      for waiter in ready { waiter.continuation.resume() }
    }
  }

  func waitForRequest(count: Int = 1) async {
    if requestedURLs.count >= count { return }
    await withCheckedContinuation { requestWaiters.append((count, $0)) }
  }

  func respond(_ response: ProfileHTTPResponse, at index: Int = 0) {
    precondition(replies.indices.contains(index))
    replies.remove(at: index).resume(returning: response)
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

@Suite("App AutoEQ acquisition consumer", .timeLimit(.minutes(1)))
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
    #expect(fixture.automation.search(query: "", favoritesOnly: true).map(\.id) == ["A"])
    #expect(fixture.automation.search(query: "Profile", favoritesOnly: true).map(\.id) == ["A"])
    #expect(await fixture.http.requestedURLs.isEmpty)
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
    // The spy intentionally does not apply commands: projection must keep reading its saved port.
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
    #expect(try fixture.files.readImportedProfiles().first?.id == imported.id)
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

  @Test("Startup restores imported and selected fetched disk caches before returning")
  func localCorrectionIsReadyBeforeHTTP() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    try fixture.files.writeImportedProfile(text: text, name: "Local", id: "local")
    try fixture.files.writeFetchedText(text, id: "A")
    fixture.preferences.selections["origin"] = AutoEQSelection(profileID: "A", isEnabled: true)
    let startup = fixture.automation.start()
    #expect(fixture.cache.profile(for: "local") != nil)
    #expect(fixture.cache.profile(for: "A") != nil)
    await startup?.value
    #expect(fixture.repository.catalogState == .ready)
    #expect(await fixture.http.requestedURLs.isEmpty)
  }

  @Test("A late A response cannot resave A after a newer B selection")
  func lateProfileCannotOverwriteNewerSelection() async throws {
    let fixture = try await fixture(cachedProfiles: [profile("B")])
    defer { fixture.cleanUp() }
    let selectedA = AutoEQSelection(profileID: "A", isEnabled: true)
    fixture.preferences.selections["origin"] = selectedA
    let first = try #require(fixture.automation.select(selectedA, forDeviceUID: "origin"))
    await fixture.http.waitForRequest()
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
    await fixture.http.waitForRequest()
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
    await fixture.http.waitForRequest()
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
    await fixture.http.waitForRequest()
    await fixture.http.respond(ProfileHTTPResponse(data: Data(), statusCode: 503))
    await task.value
    let presentation = fixture.automation.presentation(for: "origin")
    #expect(presentation.selection == selected)
    #expect(presentation.isMissing)
    #expect(!presentation.isResolving)
    #expect(presentation.selectionError?.contains("503") == true)
    #expect(
      fixture.commands.commands == [.setAutoEQSelection(deviceUID: "origin", selection: selected)])
  }

  @Test("Catalog failure is distinct from an empty local search")
  func catalogFailureIsObservable() async throws {
    let fixture = try await fixture(prepareCatalog: false)
    defer { fixture.cleanUp() }
    let task = fixture.automation.start()
    await fixture.http.waitForRequest()
    await fixture.http.respond(ProfileHTTPResponse(data: Data(), statusCode: 503))
    await task?.value
    guard case .failed(let message) = fixture.automation.presentation(for: "origin").catalogState
    else {
      Issue.record("Expected an explicit failed catalog presentation")
      return
    }
    #expect(message.contains("503"))
    #expect(fixture.automation.search(query: "Profile", favoritesOnly: false).isEmpty)
  }

  @Test(
    "An old canceled catalog request cannot demote a successful restarted service",
    arguments: [200, 503])
  func canceledCatalogCannotOverwriteRestartedReady(oldStatus: Int) async throws {
    let fixture = try await fixture(prepareCatalog: false)
    defer { fixture.cleanUp() }
    let first = fixture.automation.start()
    await fixture.http.waitForRequest()
    fixture.automation.stop()
    let restarted = fixture.automation.start()
    await fixture.http.waitForRequest(count: 2)
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
    #expect(try fixture.files.readCatalog()?.entries.map(\.id) == ["newest-b"])
    #expect(fixture.repository.catalogState == .ready)
    #expect(fixture.repository.catalogError == nil)
    #expect(fixture.automation.presentation(for: "origin").catalogState == .ready)
  }

  @Test("Delete failure preserves the committed cache; a successful retry clears its old error")
  func deleteRetryPreservesWishAndReportsItsOutcome() async throws {
    let fixture = try await fixture()
    defer { fixture.cleanUp() }
    let input = fixture.directory.appendingPathComponent("selected-input.txt")
    try text.write(to: input, atomically: true, encoding: .utf8)
    let imported = try fixture.automation.importProfile(
      forDeviceUID: "origin", from: input, name: "Imported"
    ).get()
    let saved = AutoEQSelection(profileID: imported.id, isEnabled: true)
    fixture.preferences.selections["origin"] = saved
    let profiles = fixture.directory.appendingPathComponent("AutoEQ")
    let held = fixture.directory.appendingPathComponent("AutoEQ-held")
    let intendedParent = fixture.directory.resolvingSymlinksInPath()
    #expect(profiles.resolvingSymlinksInPath().deletingLastPathComponent() == intendedParent)
    #expect(held.resolvingSymlinksInPath().deletingLastPathComponent() == intendedParent)
    try FileManager.default.moveItem(at: profiles, to: held)
    try Data("A regular file blocks the profile directory".utf8).write(to: profiles)
    let failed = fixture.automation.deleteImportedProfile(id: imported.id)
    #expect(throws: (any Error).self) { try failed.get() }
    #expect(fixture.cache.profile(for: imported.id) == imported)
    #expect(fixture.automation.presentation(for: "origin").selectionError != nil)
    #expect(fixture.preferences.selections["origin"] == saved)
    try FileManager.default.removeItem(at: profiles)
    try FileManager.default.moveItem(at: held, to: profiles)
    try fixture.automation.deleteImportedProfile(id: imported.id).get()
    let after = fixture.automation.presentation(for: "origin")
    #expect(fixture.cache.profile(for: imported.id) == nil)
    #expect(after.selection == saved)
    #expect(after.isMissing)
    #expect(after.selectionError == nil)
    #expect(fixture.commands.commands.last == .profileAvailabilityChanged(profileID: imported.id))
  }
}

@MainActor
private final class AutomationLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@Suite("URL grammar through the real shared controller and isolated settings")
@MainActor
struct URLCommandClosedLoopTests {
  private let active = "Com.Active"
  private let inactive = "Com.Inactive"
  private let eq = EQSettings(bandGains: [2, -3, 1], isEnabled: true)

  private func settingsFixture() -> (SettingsManager, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTuneURLControl-\(UUID().uuidString)", isDirectory: true)
    return (
      SettingsManager(directory: directory, launchAtLoginService: AutomationLoginService()),
      directory
    )
  }

  private func cleanUp(_ settings: SettingsManager, directory: URL) {
    settings.flushSync()
    precondition(directory.lastPathComponent.hasPrefix("FineTuneURLControl-"))
    precondition(
      directory.resolvingSymlinksInPath().deletingLastPathComponent()
        == FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
    if FileManager.default.fileExists(atPath: directory.path) {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func observeActive(_ controller: AudioController) {
    controller.observeOutputs(
      ["A", "B"].map {
        AudioOutputDescriptor(
          uid: $0, bindingRevision: 1, supportsAutoEQ: false,
          processingGain: 1, volume: 1, isMuted: false)
      }, defaultUID: "A")
    controller.observeApplications([
      AudioApplicationDescriptor(
        identifier: active, processID: 101, processRevision: 1,
        displayName: "Active", bundleID: active)
    ])
  }

  @discardableResult
  private func dispatch(_ text: String, to urls: URLAutomationController) throws
    -> URLAutomationPlan
  {
    urls.handleURL(try #require(URL(string: text)))
  }

  @Test("Inactive URL volume, mute and toggle preserve independent fields across real reload")
  func inactiveURLWritesReachTheOneStore() throws {
    let (settings, directory) = settingsFixture()
    defer { cleanUp(settings, directory: directory) }
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let urls = URLAutomationController(commandHandler: controller)
    controller.perform(.setBoost(identifier: inactive, boost: .x3))
    controller.perform(.setEQ(identifier: inactive, settings: eq))
    controller.perform(.setRoute(identifier: inactive, mode: .multi, uids: ["A", "B"]))
    controller.perform(.setMuted(identifier: inactive, muted: true))
    try dispatch("finetune://set-volumes?app=\(inactive)&volume=25", to: urls)
    #expect(settings.getVolume(for: inactive) == 0.25)
    #expect(settings.getMute(for: inactive) == true)
    try dispatch("finetune://set-mute?app=\(inactive)&muted=false", to: urls)
    #expect(settings.getMute(for: inactive) == false)
    try dispatch("finetune://toggle-mute?app=\(inactive)", to: urls)
    #expect(settings.getMute(for: inactive) == true)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
    settings.flushSync()
    let restored = SettingsManager(
      directory: directory, launchAtLoginService: AutomationLoginService())
    #expect(restored.getVolume(for: inactive) == 0.25)
    #expect(restored.getMute(for: inactive) == true)
    #expect(restored.getBoost(for: inactive) == .x3)
    #expect(restored.getEQSettings(for: inactive) == eq)
    #expect(restored.getDeviceSelectionMode(for: inactive) == .multi)
    #expect(restored.getSelectedDeviceUIDs(for: inactive) == ["A", "B"])
  }

  @Test("URL slider steps preserve mute; step and single-device writes require an observed app")
  func activeOnlyURLPolicyUsesObservedValues() throws {
    let (settings, directory) = settingsFixture()
    defer { cleanUp(settings, directory: directory) }
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    observeActive(controller)
    let urls = URLAutomationController(commandHandler: controller)
    controller.perform(.setGain(identifier: active, gain: 0.25))
    controller.perform(.setMuted(identifier: active, muted: true))
    controller.perform(.setGain(identifier: inactive, gain: 0.16))
    controller.perform(.setMuted(identifier: inactive, muted: true))
    controller.perform(.setRoute(identifier: inactive, mode: .multi, uids: ["saved"]))
    try dispatch("finetune://step-volume?app=\(active)&direction=up", to: urls)
    try dispatch("finetune://step-volume?app=\(inactive)&direction=up", to: urls)
    try dispatch("finetune://set-device?app=\(active)&device=B", to: urls)
    try dispatch("finetune://set-device?app=\(inactive)&device=B", to: urls)
    let stepped = try #require(settings.getVolume(for: active))
    #expect(abs(stepped - 0.3025) < 0.000001)
    #expect(settings.getMute(for: active) == true)
    #expect(settings.getDeviceSelectionMode(for: active) == .single)
    #expect(settings.getSelectedDeviceUIDs(for: active) == ["B"])
    #expect(settings.getVolume(for: inactive) == 0.16)
    #expect(settings.getMute(for: inactive) == true)
    #expect(settings.getDeviceSelectionMode(for: inactive) == .multi)
    #expect(settings.getSelectedDeviceUIDs(for: inactive) == ["saved"])
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
  }

  @Test("Nil-only reset is rejected; all-active and explicit-inactive reset touch gain/mute only")
  func resetScopeAndUnrelatedFieldsSurviveReload() throws {
    let (settings, directory) = settingsFixture()
    defer { cleanUp(settings, directory: directory) }
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    observeActive(controller)
    let urls = URLAutomationController(commandHandler: controller)
    for id in [active, inactive] {
      controller.perform(.setGain(identifier: id, gain: 0.2))
      controller.perform(.setMuted(identifier: id, muted: true))
      controller.perform(.setBoost(identifier: id, boost: .x3))
      controller.perform(.setEQ(identifier: id, settings: eq))
      controller.perform(.setRoute(identifier: id, mode: .multi, uids: ["A", "B"]))
    }
    let rejected = try dispatch("finetune://reset?app", to: urls)
    #expect(!rejected.diagnostics.isEmpty)
    #expect(settings.getVolume(for: active) == 0.2)
    #expect(settings.getMute(for: active) == true)
    try dispatch("finetune://reset", to: urls)
    #expect(settings.getVolume(for: active) == 1)
    #expect(settings.getMute(for: active) == false)
    #expect(settings.getVolume(for: inactive) == 0.2)
    #expect(settings.getMute(for: inactive) == true)
    try dispatch("finetune://reset?app=\(inactive)", to: urls)
    settings.flushSync()
    let restored = SettingsManager(
      directory: directory, launchAtLoginService: AutomationLoginService())
    for id in [active, inactive] {
      #expect(restored.getVolume(for: id) == 1)
      #expect(restored.getMute(for: id) == false)
      #expect(restored.getBoost(for: id) == .x3)
      #expect(restored.getEQSettings(for: id) == eq)
      #expect(restored.getDeviceSelectionMode(for: id) == .multi)
      #expect(restored.getSelectedDeviceUIDs(for: id) == ["A", "B"])
    }
    #expect(!restored.appSettings.explicitUserCaptureEnabled)
  }
}
