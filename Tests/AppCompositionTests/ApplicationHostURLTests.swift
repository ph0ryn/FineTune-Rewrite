import FineTuneControl
import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("Host URL handoff without NSApplication or live services")
@MainActor
struct ApplicationHostURLTests {
  @Test(
    "Early URL batches keep FIFO order and drain once; later URLs reach the same Common immediately"
  )
  func earlyURLsReachTheSameStoreOnce() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "FineTuneHostURLs-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = SettingsManager(
      directory: directory, launchAtLoginService: HostURLLoginService())
    let controller = AudioController(
      settings: settings, runtime: nil, profileLookup: { _ in nil },
      readDefaultRoutingDecision: { .followObserved })
    let automation = URLAutomationController(commandHandler: controller)
    let host = ApplicationHost()
    let identifier = "unit.early-a"
    let other = "unit.early-b"
    host.receiveOpenURLs([
      try #require(URL(string: "finetune://set-mute?app=\(identifier)&muted=false")),
      try #require(URL(string: "finetune://toggle-mute?app=\(identifier)")),
    ])
    host.receiveOpenURLs([
      try #require(
        URL(string: "finetune://set-volumes?app=\(identifier)&volume=25&app=\(other)&volume=75"))
    ])
    #expect(settings.getVolume(for: identifier) == nil)
    #expect(settings.getMute(for: identifier) == nil)
    host.attachURLAutomation(automation)
    #expect(controller.commandFailure == nil)
    #expect(settings.getVolume(for: identifier) == 0.25)
    #expect(settings.getVolume(for: other) == 0.75)
    #expect(settings.getMute(for: identifier) == true)

    controller.perform(.setGain(identifier: identifier, gain: 0.42))
    controller.perform(.setMuted(identifier: identifier, muted: false))
    host.attachURLAutomation(automation)
    #expect(settings.getVolume(for: identifier) == 0.42)
    #expect(settings.getMute(for: identifier) == false)
    host.receiveOpenURLs([
      try #require(URL(string: "finetune://toggle-mute?app=\(identifier)"))
    ])
    #expect(settings.getMute(for: identifier) == true)
    #expect(settings.getVolume(for: identifier) == 0.42)
    #expect(controller.captureIntent == .none)
    #expect(!settings.appSettings.explicitUserCaptureEnabled)
    settings.flushSync()
    #expect(settings.lastSaveError == nil)
    let saved = try JSONDecoder().decode(
      SavedSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    #expect(saved.appVolumes[identifier] == 0.42 && saved.appVolumes[other] == 0.75)
    #expect(saved.appMutes[identifier] == true)
  }
}

@MainActor
private final class HostURLLoginService: LaunchAtLoginService {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws {
    Issue.record("Host URL delivery must not change login state")
  }
}
