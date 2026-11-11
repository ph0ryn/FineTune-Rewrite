import FineTuneDomain
import FineTunePlatform
import Foundation
import Testing

@testable import FineTune

@Suite("System alert silencing")
@MainActor
struct SystemAlertSilencingTests {
  @Test("Only a software mute of the system-sounds device needs the OS alert mirror")
  func policy() {
    #expect(SystemAlertSilencing.shouldSilence(nil) == false)
    let hardwareMuted = SystemAlertSilencingTarget(
      deviceUID: "speaker", tier: .hardware, isMuted: true)
    let ddcMuted = SystemAlertSilencingTarget(deviceUID: "speaker", tier: .ddc, isMuted: true)
    let softwareLive = SystemAlertSilencingTarget(
      deviceUID: "speaker", tier: .software, isMuted: false)
    let softwareMuted = SystemAlertSilencingTarget(
      deviceUID: "speaker", tier: .software, isMuted: true)
    #expect(SystemAlertSilencing.shouldSilence(hardwareMuted) == false)
    #expect(SystemAlertSilencing.shouldSilence(ddcMuted) == false)
    #expect(SystemAlertSilencing.shouldSilence(softwareLive) == false)
    #expect(SystemAlertSilencing.shouldSilence(softwareMuted) == true)
  }

  @Test("A software mute saves and zeroes the alert volume; unmuting restores it")
  func muteRoundTrip() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(!fixture.silencing.isSilenced)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.silencing.isSilenced && fixture.silencing.lastError == nil)
    #expect(fixture.alertVolume.observedVolume == 0)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.8)
    #expect(fixture.scripts.currentPercent == 0)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: false))
    await fixture.silencing.awaitTransitions()
    #expect(!fixture.silencing.isSilenced)
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.scripts.currentPercent == 80)
  }

  @Test("Hardware and DDC mutes stay passive and repeated projections do no work")
  func passiveTiers() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()

    for tier in [VolumeControlTier.hardware, .ddc] {
      let target = SystemAlertSilencingTarget(
        deviceUID: "speaker", tier: tier, isMuted: true)
      fixture.silencing.update(target: target)
      fixture.silencing.update(target: target)
      await fixture.silencing.awaitTransitions()
      #expect(!fixture.silencing.isSilenced && fixture.silencing.lastError == nil)
    }
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.scripts.calls.allSatisfy { $0.hasPrefix("get ") })
  }

  @Test("An interrupted silencing is restored before the current mute is captured again")
  func interruptedRestoreRunsFirst() async {
    let fixture = SilencingFixture(percent: 0)
    defer { fixture.cleanUp() }
    // The previous process left both the restore value and the OS at zero.
    fixture.settings.setAlertVolumeBeforeMuteSilencing(0.5)

    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    #expect(fixture.alertVolume.observedVolume == 0.5)
    #expect(fixture.scripts.currentPercent == 50)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(!fixture.silencing.isSilenced)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.silencing.isSilenced)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.5)
    #expect(fixture.scripts.currentPercent == 0)
  }

  @Test("A rejected silence write keeps the alert volume and reports the failure")
  func rejectedSilence() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.scripts.setWriteStatus(1)

    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(!fixture.silencing.isSilenced)
    #expect(fixture.silencing.lastError != nil)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
    #expect(fixture.alertVolume.observedVolume == 0.8)
    #expect(fixture.scripts.currentPercent == 80)
  }

  @Test("Will-terminate restores the saved alert volume without awaiting")
  func terminationRestore() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.scripts.currentPercent == 0)

    fixture.silencing.prepareForTermination()
    #expect(fixture.scripts.currentPercent == 80)
    // The persisted value stays so a write racing the exit is finished on the next launch.
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == 0.8)
    #expect(!fixture.silencing.isSilenced)
  }

  @Test("Stopping the silencing owner restores an active mute")
  func stopRestores() async {
    let fixture = SilencingFixture()
    defer { fixture.cleanUp() }
    fixture.silencing.start()
    await fixture.silencing.awaitTransitions()
    fixture.silencing.update(target: .init(deviceUID: "speaker", tier: .software, isMuted: true))
    await fixture.silencing.awaitTransitions()
    #expect(fixture.scripts.currentPercent == 0)

    await fixture.silencing.stop()
    #expect(fixture.scripts.currentPercent == 80)
    #expect(fixture.settings.alertVolumeBeforeMuteSilencing == nil)
  }
}

@MainActor
private final class SilencingFixture {
  let directory: URL
  let scripts: AlertVolumeScripts
  let settings: SettingsManager
  let alertVolume: AlertVolumeBackend
  let silencing: SystemAlertSilencing

  init(percent: Int = 80) {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "system-alert-silencing-\(UUID())")
    scripts = AlertVolumeScripts(percent: percent)
    settings = SettingsManager(
      directory: directory, launchAtLoginService: SilencingLoginService())
    alertVolume = AlertVolumeBackend(
      scriptRunner: scripts, clock: DeviceBackendClock { _ in },
      blockingScript: { [scripts] script in scripts.runBlocking(script: script) })
    silencing = SystemAlertSilencing(alertVolume: alertVolume, settings: settings)
  }

  func cleanUp() {
    let base = FileManager.default.temporaryDirectory.standardizedFileURL
    precondition(directory.deletingLastPathComponent().standardizedFileURL == base)
    precondition(directory.lastPathComponent.hasPrefix("system-alert-silencing-"))
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class SilencingLoginService: LaunchAtLoginService {
  var isEnabled = false
  func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

/// Stateful alert-script host shared by the async and the will-terminate (blocking) paths.
private final class AlertVolumeScripts: DeviceScriptRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var percent: Int
  private var writeStatus: Int32 = 0
  private var recorded: [String] = []

  init(percent: Int) {
    self.percent = percent
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var currentPercent: Int {
    lock.lock()
    defer { lock.unlock() }
    return percent
  }

  func setWriteStatus(_ status: Int32) {
    lock.lock()
    writeStatus = status
    lock.unlock()
  }

  func run(script: String) async throws -> DeviceScriptResult {
    perform(script)
  }

  func runBlocking(script: String) -> DeviceScriptResult {
    perform(script)
  }

  private func perform(_ script: String) -> DeviceScriptResult {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(script)
    if script == "get alert volume of (get volume settings)" {
      return DeviceScriptResult(status: 0, output: "\(percent)\n")
    }
    let prefix = "set volume alert volume "
    guard script.hasPrefix(prefix), let requested = Int(script.dropFirst(prefix.count)) else {
      return DeviceScriptResult(status: 1, output: "Unexpected unit-test script.")
    }
    if writeStatus != 0 {
      return DeviceScriptResult(status: writeStatus, output: "Script denied.")
    }
    percent = requested
    return DeviceScriptResult(status: 0, output: "")
  }
}
