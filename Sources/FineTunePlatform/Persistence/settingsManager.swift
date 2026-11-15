import FineTuneDomain
import Foundation
import Observation

/// Observable settings adapter. JSON, disk I/O and OS registration have separate owners.
/// All mutations use one debounced writer; callers can explicitly flush at a shutdown boundary.
@Observable
@MainActor
public final class SettingsManager {
  public typealias Settings = SavedSettings

  private static let debounceInterval = Duration.milliseconds(500)

  private var settings = Settings()
  @ObservationIgnored private let fileStore: SettingsFileStore
  @ObservationIgnored private let launchAtLoginService: any LaunchAtLoginService
  @ObservationIgnored private let debounceSleep: @Sendable (Duration) async throws -> Void
  /// Internal test seam: the scheduled debounced write, readable but not replaceable outside this
  /// type so a test can await that exact task's completion instead of polling the file.
  @ObservationIgnored private(set) var saveTask: Task<Void, Never>?
  @ObservationIgnored private var writeBlockedAfterLoadFailure = false

  public private(set) var lastLoadError: String?
  public private(set) var lastSaveError: String?
  public private(set) var lastLaunchAtLoginError: String?

  /// The composition root must choose a directory explicitly; this library never
  /// implicitly opens the original app's settings. Loading does not register login.
  public convenience init(
    directory: URL,
    launchAtLoginService: any LaunchAtLoginService = SystemLaunchAtLoginService()
  ) {
    self.init(
      directory: directory, launchAtLoginService: launchAtLoginService,
      debounceSleep: { duration in try await Task.sleep(for: duration) })
  }

  /// Internal seam only: tests replace the wall-clock debounce with a controlled sleeper so a
  /// scheduled write is proven without a real-time race. The requested interval is passed through
  /// so a test can verify the scheduler asked for the intended duration. Production always waits
  /// for `debounceInterval`.
  init(
    directory: URL, launchAtLoginService: any LaunchAtLoginService,
    debounceSleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    fileStore = SettingsFileStore(directory: directory)
    self.launchAtLoginService = launchAtLoginService
    self.debounceSleep = debounceSleep
    do {
      if let loaded = try fileStore.load() { settings = loaded }
    } catch {
      lastLoadError = String(describing: error)
      do {
        try fileStore.backupInvalidFile()
      } catch {
        lastLoadError = "\(lastLoadError ?? "Load failed"); backup failed: \(error)"
        writeBlockedAfterLoadFailure = true
      }
    }
  }

  deinit { saveTask?.cancel() }

  public var appSettings: AppSettings {
    get { settings.appSettings }
    set { updateAppSettings(newValue) }
  }

  public var isLaunchAtLoginEnabled: Bool { launchAtLoginService.isEnabled }

  public func updateAppSettings(_ newSettings: AppSettings) {
    if newSettings.launchAtLogin != settings.appSettings.launchAtLogin {
      applyLoginRegistration(newSettings.launchAtLogin)
    }
    change { $0.appSettings = newSettings }
  }

  public func flushSync() {
    saveTask?.cancel()
    saveTask = nil
    guard !writeBlockedAfterLoadFailure else {
      lastSaveError =
        "Settings write blocked because the unreadable file could not be backed up. Resolve the load error and reinitialize the store."
      return
    }
    do {
      try fileStore.write(settings)
      lastSaveError = nil
    } catch {
      lastSaveError = String(describing: error)
    }
  }

  private func change(_ update: (inout Settings) -> Void) {
    update(&settings)
    saveTask?.cancel()
    let debounceSleep = debounceSleep
    saveTask = Task { @MainActor [weak self] in
      do {
        try await debounceSleep(Self.debounceInterval)
      } catch {
        // The debounce wait throws on cancellation: superseded writes must not reach disk.
        return
      }
      guard !Task.isCancelled else { return }
      self?.flushSync()
    }
  }

  private func applyLoginRegistration(_ enabled: Bool) {
    do {
      try launchAtLoginService.setEnabled(enabled)
      lastLaunchAtLoginError = nil
    } catch {
      lastLaunchAtLoginError = String(describing: error)
    }
  }

  public func getVolume(for identifier: String) -> Float? { settings.appVolumes[identifier] }
  public func setVolume(for identifier: String, to volume: Float) {
    change { $0.appVolumes[identifier] = volume }
  }
  public func getMute(for identifier: String) -> Bool? { settings.appMutes[identifier] }
  public func setMute(for identifier: String, to muted: Bool) {
    change { $0.appMutes[identifier] = muted }
  }
  public func getBoost(for identifier: String) -> BoostLevel? {
    settings.appBoosts[identifier].flatMap(BoostLevel.init(rawValue:))
  }
  public func setBoost(for identifier: String, to boost: BoostLevel) {
    change { $0.appBoosts[identifier] = boost.rawValue }
  }
  public func getDeviceRouting(for identifier: String) -> String? {
    settings.appDeviceRouting[identifier]
  }
  public func setDeviceRouting(for identifier: String, deviceUID: String) {
    change { $0.appDeviceRouting[identifier] = deviceUID }
  }
  public func isFollowingDefault(for identifier: String) -> Bool {
    getDeviceRouting(for: identifier) == nil
  }
  public func setFollowDefault(for identifier: String) {
    change { $0.appDeviceRouting[identifier] = nil }
  }
  public var isSystemSoundsFollowingDefault: Bool { settings.systemSoundsFollowsDefault }
  public func setSystemSoundsFollowDefault(_ follows: Bool) {
    change { $0.systemSoundsFollowsDefault = follows }
  }
  public func getEQSettings(for appIdentifier: String) -> EQSettings {
    settings.appEQSettings[appIdentifier] ?? .flat
  }
  public func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
    change { $0.appEQSettings[appIdentifier] = eqSettings }
  }
  public func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
    settings.appDeviceSelectionMode[identifier]
  }
  public func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
    change { $0.appDeviceSelectionMode[identifier] = mode }
  }
  public func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
    settings.appSelectedDeviceUIDs[identifier].map(Set.init)
  }
  public func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
    change { $0.appSelectedDeviceUIDs[identifier] = Array(uids) }
  }

  public var lockedInputDeviceUID: String? { settings.lockedInputDeviceUID }
  public var preferredInputDeviceUID: String? { settings.preferredInputDeviceUID }
  public func setLockedInputDeviceUID(_ uid: String?) {
    change { $0.lockedInputDeviceUID = uid }
  }
  public func setPreferredInputDeviceUID(_ uid: String?) {
    change { $0.preferredInputDeviceUID = uid }
  }

  public func pinApp(_ identifier: String, info: PinnedAppInfo) {
    change {
      $0.pinnedApps.insert(identifier)
      $0.pinnedAppInfo[identifier] = info
    }
  }
  public func unpinApp(_ identifier: String) {
    change {
      $0.pinnedApps.remove(identifier)
      $0.pinnedAppInfo[identifier] = nil
    }
  }
  public func isPinned(_ identifier: String) -> Bool { settings.pinnedApps.contains(identifier) }
  public func getPinnedAppInfo() -> [PinnedAppInfo] {
    settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
  }
  public func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
    change {
      $0.ignoredApps.insert(identifier)
      $0.ignoredAppInfo[identifier] = info
      $0.pinnedApps.remove(identifier)
      $0.pinnedAppInfo[identifier] = nil
      Self.removeAppValues(identifier, from: &$0)
      $0.appDeviceRouting[identifier] = nil
    }
  }
  public func unignoreApp(_ identifier: String) {
    change {
      $0.ignoredApps.remove(identifier)
      $0.ignoredAppInfo[identifier] = nil
    }
  }
  public func isIgnored(_ identifier: String) -> Bool { settings.ignoredApps.contains(identifier) }
  public func getIgnoredAppInfo() -> [IgnoredAppInfo] {
    settings.ignoredApps.compactMap { settings.ignoredAppInfo[$0] }
  }

  public func getDDCVolume(for deviceUID: String) -> Int? { settings.ddcVolumes[deviceUID] }
  public func setDDCVolume(for deviceUID: String, to volume: Int) {
    change { $0.ddcVolumes[deviceUID] = volume }
  }
  public func getDDCMuteState(for deviceUID: String) -> Bool {
    settings.ddcMuteStates[deviceUID] ?? false
  }
  public func setDDCMuteState(for deviceUID: String, to muted: Bool) {
    change { $0.ddcMuteStates[deviceUID] = muted }
  }
  public func getDDCSavedVolume(for deviceUID: String) -> Int? {
    settings.ddcSavedVolumes[deviceUID]
  }
  public func setDDCSavedVolume(for deviceUID: String, to volume: Int) {
    change { $0.ddcSavedVolumes[deviceUID] = volume }
  }
  public func getSoftwareDeviceVolume(for deviceUID: String) -> Float? {
    settings.softwareDeviceVolumes[deviceUID]
  }
  public func setSoftwareDeviceVolume(for deviceUID: String, to volume: Float) {
    change { $0.softwareDeviceVolumes[deviceUID] = Self.normalizedDeviceGain(volume) }
  }
  public func getSoftwareDeviceSavedVolume(for deviceUID: String) -> Float? {
    settings.softwareDeviceSavedVolumes[deviceUID]
  }
  public func setSoftwareDeviceSavedVolume(for deviceUID: String, to volume: Float) {
    change { $0.softwareDeviceSavedVolumes[deviceUID] = Self.normalizedDeviceGain(volume) }
  }
  public func getSoftwareDeviceMuteState(for deviceUID: String) -> Bool {
    settings.softwareDeviceMuteStates[deviceUID] ?? false
  }
  public func setSoftwareDeviceMuteState(for deviceUID: String, to muted: Bool) {
    change { $0.softwareDeviceMuteStates[deviceUID] = muted }
  }
  /// Only the alert-silencing mirror writes this; its presence means a restore is still owed.
  public var alertVolumeBeforeMuteSilencing: Float? {
    settings.alertVolumeBeforeMuteSilencing
  }
  public func setAlertVolumeBeforeMuteSilencing(_ volume: Float?) {
    change { $0.alertVolumeBeforeMuteSilencing = volume }
  }
  private static func normalizedDeviceGain(_ volume: Float) -> Float {
    volume.isFinite ? max(0, min(1, volume)) : 1
  }
  public func getDeviceVolumeTierOverride(for deviceUID: String) -> VolumeControlTier? {
    settings.deviceVolumeTierOverride[deviceUID]
  }
  public func setDeviceVolumeTierOverride(for deviceUID: String, to tier: VolumeControlTier?) {
    change { $0.deviceVolumeTierOverride[deviceUID] = tier }
  }
  public var deviceIconOverrides: [String: String] { settings.deviceIconOverrides }
  public func getDeviceIconOverride(for deviceUID: String) -> String? {
    settings.deviceIconOverrides[deviceUID]
  }
  public func setDeviceIconOverride(for deviceUID: String, to symbol: String?) {
    change { $0.deviceIconOverrides[deviceUID] = symbol }
  }

  public var devicePriorityOrder: [String] { settings.outputDevicePriority }
  public var inputDevicePriorityOrder: [String] { settings.inputDevicePriority }
  public func setDevicePriorityOrder(_ uids: [String]) {
    change { $0.outputDevicePriority = uids }
  }
  public func setInputDevicePriorityOrder(_ uids: [String]) {
    change { $0.inputDevicePriority = uids }
  }
  public func ensureDeviceInPriority(_ uid: String) {
    guard !devicePriorityOrder.contains(uid) else { return }
    change { $0.outputDevicePriority.append(uid) }
  }
  public func ensureInputDeviceInPriority(_ uid: String) {
    guard !inputDevicePriorityOrder.contains(uid) else { return }
    change { $0.inputDevicePriority.append(uid) }
  }
  public func mergeDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
    setDevicePriorityOrder(
      Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder))
  }
  public func mergeInputDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
    setInputDevicePriorityOrder(
      Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder))
  }

  /// Preserve each disconnected run after its former preceding connected device.
  public static func mergePriorityOrder(oldPriority: [String], connectedOrder: [String]) -> [String]
  {
    let connected = Set(connectedOrder)
    var runs: [String: [String]] = [:]
    var prefix: [String] = []
    var predecessor: String?
    for uid in oldPriority {
      if connected.contains(uid) {
        predecessor = uid
      } else if let predecessor {
        runs[predecessor, default: []].append(uid)
      } else {
        prefix.append(uid)
      }
    }
    return prefix + connectedOrder.flatMap { [$0] + (runs[$0] ?? []) }
  }

  public var hiddenOutputDeviceUIDs: Set<String> { settings.hiddenOutputDeviceUIDs }
  public var hiddenInputDeviceUIDs: Set<String> { settings.hiddenInputDeviceUIDs }
  public func isOutputDeviceHidden(_ uid: String) -> Bool { hiddenOutputDeviceUIDs.contains(uid) }
  public func isInputDeviceHidden(_ uid: String) -> Bool { hiddenInputDeviceUIDs.contains(uid) }
  public func hideOutputDevice(uid: String) { change { $0.hiddenOutputDeviceUIDs.insert(uid) } }
  public func unhideOutputDevice(uid: String) { change { $0.hiddenOutputDeviceUIDs.remove(uid) } }
  public func hideInputDevice(uid: String) { change { $0.hiddenInputDeviceUIDs.insert(uid) } }
  public func unhideInputDevice(uid: String) { change { $0.hiddenInputDeviceUIDs.remove(uid) } }
  public func toggleOutputDeviceHidden(uid: String) {
    isOutputDeviceHidden(uid) ? unhideOutputDevice(uid: uid) : hideOutputDevice(uid: uid)
  }
  public func toggleInputDeviceHidden(uid: String) {
    isInputDeviceHidden(uid) ? unhideInputDevice(uid: uid) : hideInputDevice(uid: uid)
  }

  public func pruneStaleSettings(keeping activeIdentifiers: Set<String>) {
    let identifiers = Set(settings.appVolumes.keys)
      .union(settings.appBoosts.keys).union(settings.appMutes.keys)
      .union(settings.appEQSettings.keys).union(settings.appDeviceSelectionMode.keys)
      .union(settings.appSelectedDeviceUIDs.keys)
    let disposable = identifiers.filter { id in
      !activeIdentifiers.contains(id) && !settings.pinnedApps.contains(id)
        && settings.appDeviceRouting[id] == nil
        && (settings.appVolumes[id] ?? 1) == 1
        && (settings.appBoosts[id] ?? 1) == 1
        && !(settings.appMutes[id] ?? false)
        && (settings.appEQSettings[id] ?? .flat) == .flat
        && settings.appDeviceSelectionMode[id] == nil
        && (settings.appSelectedDeviceUIDs[id]?.isEmpty ?? true)
    }
    guard !disposable.isEmpty else { return }
    change { state in
      for id in disposable { Self.removeAppValues(id, from: &state) }
    }
  }

  private static func removeAppValues(_ id: String, from state: inout Settings) {
    state.appVolumes[id] = nil
    state.appMutes[id] = nil
    state.appBoosts[id] = nil
    state.appEQSettings[id] = nil
    state.appDeviceSelectionMode[id] = nil
    state.appSelectedDeviceUIDs[id] = nil
  }

  public func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
    settings.deviceAutoEQ[deviceUID]
  }
  public func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
    change { $0.deviceAutoEQ[deviceUID] = selection }
  }
  public var favoriteAutoEQProfileIDs: Set<String> { settings.favoriteAutoEQProfiles }
  public func isAutoEQFavorite(id: String) -> Bool { favoriteAutoEQProfileIDs.contains(id) }
  public func favoriteAutoEQProfile(id: String) {
    change { $0.favoriteAutoEQProfiles.insert(id) }
  }
  public func unfavoriteAutoEQProfile(id: String) {
    change { $0.favoriteAutoEQProfiles.remove(id) }
  }
  public var autoEQPreampEnabled: Bool {
    get { settings.autoEQPreampEnabled }
    set { change { $0.autoEQPreampEnabled = newValue } }
  }

  public func getUserPresets() -> [UserEQPreset] {
    settings.userEQPresets.sorted { $0.createdAt > $1.createdAt }
  }
  @discardableResult
  public func createUserPreset(name: String, settings eqSettings: EQSettings) -> UserEQPreset {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let preset = UserEQPreset(
      name: availablePresetName(name.isEmpty ? "Untitled" : name), settings: eqSettings)
    change { $0.userEQPresets.append(preset) }
    return preset
  }
  public func updateUserPreset(id: UUID, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = settings.userEQPresets.firstIndex(where: { $0.id == id })
    else {
      return
    }
    let available = availablePresetName(name, excluding: id)
    change { $0.userEQPresets[index].name = available }
  }
  public func deleteUserPreset(id: UUID) {
    change { $0.userEQPresets.removeAll { $0.id == id } }
  }
  private func availablePresetName(_ name: String, excluding id: UUID? = nil) -> String {
    let taken = Set(settings.userEQPresets.filter { $0.id != id }.map(\.name))
    if !taken.contains(name) { return name }
    var suffix = 2
    while taken.contains("\(name) (\(suffix))") { suffix += 1 }
    return "\(name) (\(suffix))"
  }

  public func resetAllSettings() {
    let version = settings.version
    change {
      $0 = Settings()
      $0.version = version
    }
    applyLoginRegistration(false)
  }
}
