import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

// Independently authored tests of the new storage/service boundary (MIT).
@Suite("Persistence boundary")
@MainActor
struct PersistenceTests {
  @MainActor
  private final class LoginSpy: LaunchAtLoginService {
    enum Failure: Error { case unavailable }
    var isEnabled = false
    var requests: [Bool] = []
    var fails = false

    func setEnabled(_ enabled: Bool) throws {
      requests.append(enabled)
      if fails { throw Failure.unavailable }
      isEnabled = enabled
    }
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FineTunePersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test("Direct binding and explicit update deliver the same single login request")
  func bindingForwardsExactlyOnce() throws {
    let firstDirectory = try temporaryDirectory()
    let secondDirectory = try temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: firstDirectory)
      try? FileManager.default.removeItem(at: secondDirectory)
    }
    let firstSpy = LoginSpy()
    let secondSpy = LoginSpy()
    let direct = SettingsManager(directory: firstDirectory, launchAtLoginService: firstSpy)
    let explicit = SettingsManager(directory: secondDirectory, launchAtLoginService: secondSpy)
    var preferences = direct.appSettings
    preferences.launchAtLogin = true
    preferences.defaultNewAppVolume = 0.42
    direct.appSettings = preferences
    explicit.updateAppSettings(preferences)
    direct.appSettings = preferences
    #expect(firstSpy.requests == [true])
    #expect(secondSpy.requests == [true])
    #expect(direct.appSettings == explicit.appSettings)
    #expect(direct.isLaunchAtLoginEnabled)
    direct.flushSync()
    let readback = SettingsManager(directory: firstDirectory, launchAtLoginService: LoginSpy())
    #expect(readback.appSettings == preferences)
  }

  @Test("Loading a login preference never registers it as a side effect")
  func initializationDoesNotWriteToOS() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var saved = SavedSettings()
    saved.appSettings.launchAtLogin = true
    try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("settings.json"))
    let spy = LoginSpy()
    let manager = SettingsManager(directory: directory, launchAtLoginService: spy)
    #expect(manager.appSettings.launchAtLogin)
    #expect(spy.requests.isEmpty)
    #expect(manager.lastLoadError == nil)
  }

  @Test("A failed login request remains observable without losing the saved preference")
  func loginFailureIsObservable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let spy = LoginSpy()
    spy.fails = true
    let manager = SettingsManager(directory: directory, launchAtLoginService: spy)
    manager.appSettings.launchAtLogin = true
    #expect(spy.requests == [true])
    #expect(manager.appSettings.launchAtLogin)
    #expect(manager.lastLaunchAtLoginError != nil)
    #expect(!manager.isLaunchAtLoginEnabled)
  }

  @Test("Explicit flush writes gain units, routing and mute into the isolated directory")
  func flushReadback() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    manager.setVolume(for: "app", to: 0.25)
    manager.setBoost(for: "app", to: .x4)
    manager.setMute(for: "app", to: true)
    manager.setDeviceRouting(for: "app", deviceUID: "output")
    manager.setSelectedDeviceUIDs(for: "app", to: ["output", "other"])
    manager.flushSync()
    let loaded = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    #expect(loaded.getVolume(for: "app") == 0.25)
    #expect(loaded.getBoost(for: "app") == .x4)
    #expect(loaded.getMute(for: "app") == true)
    #expect(loaded.getDeviceRouting(for: "app") == "output")
    #expect(loaded.getSelectedDeviceUIDs(for: "app") == ["output", "other"])
    #expect(manager.lastSaveError == nil)
  }

  @Test("Debounced changes persist the latest snapshot rather than the first scheduled value")
  func debounceReadback() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    manager.setVolume(for: "app", to: 0.1)
    manager.setVolume(for: "app", to: 0.7)
    try await Task.sleep(for: .milliseconds(750))
    let loaded = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    #expect(loaded.getVolume(for: "app") == 0.7)
    #expect(manager.lastSaveError == nil)
  }

  @Test("Malformed input is backed up byte-for-byte and its load error remains observable")
  func malformedBackup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("settings.json")
    let invalid = Data("{not-json".utf8)
    try invalid.write(to: file)
    let manager = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    #expect(manager.lastLoadError != nil)
    #expect(manager.getVolume(for: "app") == nil)
    #expect(try Data(contentsOf: file) == invalid)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("settings.backup.json")) == invalid)
    manager.setVolume(for: "app", to: 0.5)
    manager.flushSync()
    let loaded = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    #expect(loaded.getVolume(for: "app") == 0.5)
    #expect(loaded.lastLoadError == nil)
  }

  @Test("A type error is not mistaken for an absent optional key")
  func wrongTypeIsObservable() throws {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SavedSettings.self, from: Data(#"{"appVolumes":false}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        SavedSettings.self, from: Data(#"{"appSettings":{"hudStyle":"future"}}"#.utf8))
    }
  }

  @Test("Unknown version integers follow the original known-key decoder, not a new migration gate")
  func unknownVersionPreserved() throws {
    let input = Data(#"{"version":999,"appVolumes":{"app":0.25},"newKey":true}"#.utf8)
    let decoded = try JSONDecoder().decode(SavedSettings.self, from: input)
    #expect(decoded.version == 999)
    #expect(decoded.appVolumes["app"] == 0.25)
    let roundtrip = try JSONDecoder().decode(
      SavedSettings.self, from: JSONEncoder().encode(decoded))
    #expect(roundtrip.version == 999)
    #expect(roundtrip.appVolumes["app"] == 0.25)
  }

  @Test("Encoding failure is observable and does not replace the last valid file")
  func saveFailureIsObservable() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SettingsManager(directory: directory, launchAtLoginService: LoginSpy())
    manager.setVolume(for: "app", to: 0.25)
    manager.flushSync()
    let file = directory.appendingPathComponent("settings.json")
    let before = try Data(contentsOf: file)
    manager.setVolume(for: "app", to: .infinity)
    manager.flushSync()
    #expect(manager.lastSaveError != nil)
    #expect(try Data(contentsOf: file) == before)
    manager.setVolume(for: "app", to: 0.5)
    manager.flushSync()
    #expect(manager.lastSaveError == nil)
  }

  @Test("Missing-file initialization does not create files or call the login service")
  func missingFileHasNoSideEffects() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let spy = LoginSpy()
    let manager = SettingsManager(directory: directory, launchAtLoginService: spy)
    #expect(manager.lastLoadError == nil)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("settings.json").path))
    #expect(spy.requests.isEmpty)
  }

  @Test("Reset clears storage fields and requests unregister through the injected service")
  func resetUsesInjectedService() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let spy = LoginSpy()
    let manager = SettingsManager(directory: directory, launchAtLoginService: spy)
    manager.appSettings.launchAtLogin = true
    manager.setDeviceIconOverride(for: "output", to: "headphones")
    manager.createUserPreset(name: "A", settings: .flat)
    manager.setAutoEQSelection(
      for: "output", to: AutoEQSelection(profileID: "profile", isEnabled: true))
    manager.resetAllSettings()
    manager.flushSync()
    #expect(spy.requests == [true, false])
    let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
    let saved = try JSONDecoder().decode(SavedSettings.self, from: data)
    #expect(saved == SavedSettings())
  }
}
