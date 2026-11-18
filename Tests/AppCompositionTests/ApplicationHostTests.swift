import AppKit
import FineTuneControl
import Foundation
import Testing

@testable import FineTune

@Suite("App composition: ApplicationHost termination and URL handoff")
@MainActor
struct ApplicationHostTests {
  @Test("Quit uses normal AppKit termination with synchronous will-terminate cleanup")
  func quitDoesNotEnterDeferredTermination() {
    let host = ApplicationHost()
    #expect(!host.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminate(_:))))
    #expect(host.responds(to: #selector(NSApplicationDelegate.applicationWillTerminate(_:))))
  }

  @Test("Early URL batches drain once in FIFO order; later URLs dispatch immediately")
  func earlyURLsDrainOnceAndForwardImmediately() throws {
    let sink = HostURLCommandSink()
    let automation = URLAutomationController(commandHandler: sink)
    let host = ApplicationHost()

    host.receiveOpenURLs([
      try #require(URL(string: "finetune://set-mute?app=unit.early-a&muted=false")),
      try #require(URL(string: "finetune://toggle-mute?app=unit.early-a")),
    ])
    host.receiveOpenURLs([
      try #require(
        URL(string: "finetune://set-volumes?app=unit.early-a&volume=25&app=unit.early-b&volume=75"))
    ])
    #expect(sink.commands.isEmpty)

    host.attachURLAutomation(automation)
    #expect(
      sink.commands == [
        .setMuted(identifier: "unit.early-a", muted: false),
        .toggleMuted(identifier: "unit.early-a"),
        .setGain(identifier: "unit.early-a", gain: 0.25),
        .setGain(identifier: "unit.early-b", gain: 0.75),
      ])

    // Re-attaching must not replay already-drained URLs.
    sink.commands.removeAll()
    host.attachURLAutomation(automation)
    #expect(sink.commands.isEmpty)

    host.receiveOpenURLs([
      try #require(URL(string: "finetune://toggle-mute?app=unit.early-a"))
    ])
    #expect(sink.commands == [.toggleMuted(identifier: "unit.early-a")])
  }
}

@MainActor
private final class HostURLCommandSink: AudioCommandHandling {
  var commands: [AudioCommand] = []
  func perform(_ command: AudioCommand) { commands.append(command) }
}
