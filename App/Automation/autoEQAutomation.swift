import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Observation

/// App-owned request/lifecycle adapter. Preferences remain in the injected settings owner;
/// loaded profiles remain in the repository's shared cache. Neither is mirrored here.
@Observable
@MainActor
final class AutoEQAutomation {
  private struct ResolutionFailure {
    let profileID: String?
    let message: String
  }

  private let repository: AutoEQProfileRepository
  private let preferences: any AutoEQPreferencesReading
  private let commands: any AudioCommandHandling
  private let connectedDeviceUIDs: @MainActor () -> [String]
  private var isRunning = false
  private var isStopped = false
  private var startupError: String?
  private var pendingProfiles: [String: String] = [:]
  private var failures: [String: ResolutionFailure] = [:]
  private(set) var lastError: (any Error)?
  @ObservationIgnored private var catalogTask: Task<Void, Never>?
  @ObservationIgnored private var resolutionTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var requestTokens: [String: UUID] = [:]
  @ObservationIgnored private var lifecycleGeneration = 0

  init(
    repository: AutoEQProfileRepository, preferences: any AutoEQPreferencesReading,
    commands: any AudioCommandHandling,
    connectedDeviceUIDs: @escaping @MainActor () -> [String]
  ) {
    self.repository = repository
    self.preferences = preferences
    self.commands = commands
    self.connectedDeviceUIDs = connectedDeviceUIDs
  }

  deinit {
    catalogTask?.cancel()
    for task in resolutionTasks.values { task.cancel() }
  }

  /// Local correction is ready when this returns. The returned owned task can be awaited by callers,
  /// but composition need not retain it in a second registry or wait for HTTP before audio preparation.
  @discardableResult
  func start() -> Task<Void, Never>? {
    if isRunning { return catalogTask }
    isRunning = true
    isStopped = false
    lifecycleGeneration += 1
    let generation = lifecycleGeneration
    startupError = nil
    let ids = Set(
      connectedDeviceUIDs().compactMap { preferences.getAutoEQSelection(for: $0)?.profileID })
    do {
      let loadedIDs = try repository.loadLocalProfiles(selectedProfileIDs: ids)
      for id in loadedIDs { commands.perform(.profileAvailabilityChanged(profileID: id)) }
    } catch {
      lastError = error
      startupError = "Saved profile data could not be loaded. \(Self.message(for: error))"
    }
    let repository = repository
    let task = Task { @MainActor [weak self, repository] in
      do {
        try Task.checkCancellation()
        try await repository.loadCatalog()
      } catch {
        if !Task.isCancelled, let self, self.lifecycleGeneration == generation {
          // Repository keeps the failed phase and original error; this is a diagnostic history value.
          self.lastError = error
        }
      }
      guard !Task.isCancelled, let self, !self.isStopped,
        self.lifecycleGeneration == generation
      else { return }
      self.devicesDidChange()
    }
    catalogTask = task
    return task
  }

  /// Service teardown, not the user's Stop Capture command.
  func stop() {
    isStopped = true
    isRunning = false
    lifecycleGeneration += 1
    catalogTask?.cancel()
    catalogTask = nil
    for task in resolutionTasks.values { task.cancel() }
    resolutionTasks = [:]
    requestTokens = [:]
    pendingProfiles = [:]
  }

  func devicesDidChange() {
    guard !isStopped else { return }
    let uids = Set(connectedDeviceUIDs())
    for uid in Array(resolutionTasks.keys) where !uids.contains(uid) { cancelResolution(for: uid) }
    for uid in uids.sorted() {
      guard let selection = preferences.getAutoEQSelection(for: uid), selection.isEnabled else {
        cancelResolution(for: uid)
        continue
      }
      guard repository.profile(for: selection.profileID) == nil else { continue }
      // A failed/not-yet-loaded catalog is not evidence that an unknown saved identity is invalid.
      if repository.catalogState != .ready
        && !repository.catalog.contains(where: { $0.id == selection.profileID })
      {
        continue
      }
      _ = beginResolution(profileID: selection.profileID, deviceUID: uid)
    }
  }

  @discardableResult
  func select(_ selection: AutoEQSelection?, forDeviceUID uid: String) -> Task<Void, Never>? {
    guard !isStopped else { return nil }
    commands.perform(.setAutoEQSelection(deviceUID: uid, selection: selection))
    cancelResolution(for: uid)
    failures[uid] = nil
    guard let selection, selection.isEnabled,
      repository.profile(for: selection.profileID) == nil
    else { return nil }
    return beginResolution(profileID: selection.profileID, deviceUID: uid)
  }

  @discardableResult
  func importProfile(forDeviceUID uid: String, from url: URL, name: String) -> Result<
    AutoEQProfile, any Error
  > {
    guard !isStopped else { return .failure(CancellationError()) }
    do {
      let profile = try repository.importProfile(from: url, name: name)
      commands.perform(.profileAvailabilityChanged(profileID: profile.id))
      _ = select(AutoEQSelection(profileID: profile.id, isEnabled: true), forDeviceUID: uid)
      return .success(profile)
    } catch {
      lastError = error
      failures[uid] = ResolutionFailure(
        profileID: preferences.getAutoEQSelection(for: uid)?.profileID,
        message: Self.message(for: error))
      return .failure(error)
    }
  }

  @discardableResult
  func deleteImportedProfile(id: String) -> Result<Void, any Error> {
    guard !isStopped else { return .failure(CancellationError()) }
    do {
      try repository.deleteImportedProfile(id: id)
      failures = failures.filter { $0.value.profileID != id }
      commands.perform(.profileAvailabilityChanged(profileID: id))
      return .success(())
    } catch {
      lastError = error
      for uid in connectedDeviceUIDs()
      where preferences.getAutoEQSelection(for: uid)?.profileID == id {
        failures[uid] = ResolutionFailure(profileID: id, message: Self.message(for: error))
      }
      return .failure(error)
    }
  }

  func setFavorite(id: String, favorite: Bool) {
    guard !isStopped else { return }
    commands.perform(.setAutoEQFavorite(profileID: id, favorite: favorite))
  }

  func setPreampEnabled(_ enabled: Bool) {
    guard !isStopped else { return }
    commands.perform(.setAutoEQPreampEnabled(enabled))
  }

  func search(query: String, favoritesOnly: Bool) -> MixerProfileSearchResult {
    let entries: [AutoEQCatalogEntry]
    let totalCount: Int
    let favorites = preferences.favoriteAutoEQProfileIDs
    if query.isEmpty {
      // This local favorites query is uncapped, unlike ranked catalog search.
      entries = repository.entries(eligibleIDs: favorites)
      totalCount = entries.count
    } else {
      let result = repository.search(query: query, eligibleIDs: favoritesOnly ? favorites : nil)
      entries = result.entries
      totalCount = result.totalCount
    }
    let ordered =
      entries.filter { favorites.contains($0.id) }
      + entries.filter { !favorites.contains($0.id) }
    return MixerProfileSearchResult(
      entries: ordered.map { MixerProfileChoice(id: $0.id, name: $0.name, detail: $0.measuredBy) },
      totalCount: totalCount)
  }

  func presentation(for uid: String) -> MixerProfilePresentation {
    let selection = preferences.getAutoEQSelection(for: uid)
    let profile = selection.flatMap { repository.profile(for: $0.profileID) }
    let entry = selection.flatMap { saved in
      repository.entries().first(where: { $0.id == saved.profileID })
    }
    let name = profile?.name ?? entry?.name
    let detail: String?
    if let profile {
      detail = profile.source == .imported ? "Imported" : profile.measuredBy
    } else {
      detail = entry?.measuredBy
    }
    let catalogState: MixerProfileCatalogState
    switch repository.catalogState {
    case .idle: catalogState = .notLoaded
    case .loading: catalogState = .loading
    case .ready: catalogState = .ready
    case .failed:
      guard let error = repository.catalogError else {
        preconditionFailure("A failed catalog status must carry its original error")
      }
      catalogState = .failed(Self.message(for: error))
    }
    let failure = failures[uid].flatMap { $0.profileID == selection?.profileID ? $0.message : nil }
    return MixerProfilePresentation(
      catalogState: catalogState, selection: selection, profileName: name,
      isMissing: selection != nil && profile == nil,
      isResolving: !isStopped && selection.map { pendingProfiles[uid] == $0.profileID } == true,
      selectionError: failure ?? startupError, favoriteIDs: preferences.favoriteAutoEQProfileIDs,
      preampEnabled: preferences.autoEQPreampEnabled, profileDetail: detail)
  }

  func makeMixerInterface() -> MixerProfileInterface {
    MixerProfileInterface(
      read: { self.presentation(for: $0) },
      search: { self.search(query: $0, favoritesOnly: $1) },
      importProfile: { _ = self.importProfile(forDeviceUID: $0, from: $1, name: $2) },
      select: { _ = self.select($1, forDeviceUID: $0) },
      setFavorite: { self.setFavorite(id: $0, favorite: $1) },
      setPreampEnabled: { self.setPreampEnabled($0) })
  }

  private func beginResolution(profileID: String, deviceUID uid: String) -> Task<Void, Never> {
    if pendingProfiles[uid] == profileID, let existing = resolutionTasks[uid] { return existing }
    cancelResolution(for: uid)
    let token = UUID()
    requestTokens[uid] = token
    pendingProfiles[uid] = profileID
    failures[uid] = nil
    let repository = repository
    let task = Task { @MainActor [weak self, repository] in
      do {
        try Task.checkCancellation()
        _ = try await repository.resolveProfile(for: profileID)
        if !Task.isCancelled, let self, !self.isStopped, self.requestTokens[uid] == token {
          // Arrival is not a new selection. Control re-reads current enabled UID/profile wishes.
          self.commands.perform(.profileAvailabilityChanged(profileID: profileID))
        }
      } catch {
        if !Task.isCancelled, let self, !self.isStopped, self.requestTokens[uid] == token {
          self.lastError = error
          self.failures[uid] = ResolutionFailure(
            profileID: profileID, message: Self.message(for: error))
        }
      }
      if let self, self.requestTokens[uid] == token {
        self.requestTokens[uid] = nil
        self.pendingProfiles[uid] = nil
        self.resolutionTasks[uid] = nil
      }
    }
    resolutionTasks[uid] = task
    return task
  }

  private func cancelResolution(for uid: String) {
    resolutionTasks.removeValue(forKey: uid)?.cancel()
    requestTokens[uid] = nil
    pendingProfiles[uid] = nil
  }

  private static func message(for error: any Error) -> String {
    guard let error = error as? ProfileRepositoryError else { return error.localizedDescription }
    switch error {
    case .noValidFilters: return "The file has no supported, enabled filters."
    case .invalidIdentifier: return "The profile identity is invalid."
    case .invalidRelativePath: return "The profile catalog contains an invalid path."
    case .invalidRoot: return "The profile storage location is invalid."
    case .invalidImportURL: return "Choose a local profile text file."
    case .invalidUTF8: return "The profile data is not UTF-8 text."
    case .invalidCatalog: return "The headphone profile catalog could not be read."
    case .missingModificationDate: return "The cached profile list could not be read."
    case .unknownProfile: return "The selected profile is not in the current catalog."
    case .notImported: return "Only imported profiles can be deleted."
    case .httpStatus(let code): return "Could not download profile data (HTTP \(code))."
    }
  }
}
