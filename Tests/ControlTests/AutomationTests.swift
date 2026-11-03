import FineTuneControl
import Foundation
import Testing

// Independently authored unit coverage of the new URL-to-common-operation boundary (MIT).
@Suite("URL automation entry validation")
struct URLAutomationValidationTests {
  @Test("An explicit but valueless app never falls back to resetting every app")
  func nilOnlyResetIsInert() throws {
    let plan = URLAutomationParser.parse(try #require(URL(string: "finetune://reset?app")))
    #expect(plan.commands.isEmpty)
    #expect(!plan.diagnostics.isEmpty)
  }

  @Test("Reset without an app key retains the intended all-active action")
  func targetlessResetIsAllActive() throws {
    let plan = URLAutomationParser.parse(try #require(URL(string: "finetune://reset")))
    #expect(plan.commands.count == 1)
    #expect(plan.diagnostics.isEmpty)
  }

  @Test(
    "Empty identity and device values are rejected at the write entrance",
    arguments: [
      "finetune://set-volumes?app=&volume=50",
      "finetune://set-mute?app=&muted=yes",
      "finetune://toggle-mute?app=",
      "finetune://step-volume?app=&direction=up",
      "finetune://set-device?app=com.unit&device=",
      "finetune://set-device?app=&device=unit-output",
      "finetune://reset?app=",
    ])
  func emptyWriteTargetIsInert(input: String) throws {
    let plan = URLAutomationParser.parse(try #require(URL(string: input)))
    #expect(plan.commands.isEmpty)
    #expect(!plan.diagnostics.isEmpty)
  }

  @Test(
    "Unsupported URLs cannot produce operations",
    arguments: [
      "https://set-volumes?app=com.unit&volume=50",
      "finetune://unsupported?app=com.unit",
    ])
  func unsupportedIsInert(input: String) throws {
    let plan = URLAutomationParser.parse(try #require(URL(string: input)))
    #expect(plan.commands.isEmpty)
    #expect(!plan.diagnostics.isEmpty)
  }
}

@Suite("URL six-action normalization")
struct URLAutomationCommandTests {
  private func parse(_ input: String) throws -> URLAutomationPlan {
    URLAutomationParser.parse(try #require(URL(string: input)))
  }

  @Test(
    "Percent is linear gain, not slider or boost",
    arguments: [
      ("0", Float(0)), ("25", 0.25), ("100", 1),
    ])
  func linearPercent(percent: String, gain: Float) throws {
    let result = try parse("finetune://set-volumes?app=Com.Unit&volume=\(percent)")
    #expect(result.commands == [.setGain(identifier: "Com.Unit", gain: gain)])
  }

  @Test("Invalid volume consumes its pending app", arguments: ["-1", "101", "1.5", "bad", ""])
  func invalidVolumeCannotReuseIdentity(value: String) throws {
    let result = try parse("finetune://set-volumes?app=A&volume=\(value)&volume=75")
    #expect(result.commands.isEmpty)
    #expect(!result.diagnostics.isEmpty)
  }

  @Test("Ordered pairs, replaced app and unknown keys retain original semantics")
  func orderedPairs() throws {
    let result = try parse(
      "finetune://set-volumes?volume=2&app=Replaced&APP=Com.First&unknown=x&VOLUME=25&app=Com.Second&volume=100"
    )
    #expect(
      result.commands == [
        .setGain(identifier: "Com.First", gain: 0.25),
        .setGain(identifier: "Com.Second", gain: 1),
      ])
  }

  @Test(
    "Mute Boolean spellings preserve exact app identity",
    arguments: [
      ("true", true), ("1", true), ("YES", true), ("false", false), ("0", false), ("No", false),
    ])
  func muteValues(value: String, expected: Bool) throws {
    let result = try parse("finetune://set-mute?APP=Com.Unit&MUTED=\(value)")
    #expect(result.commands == [.setMuted(identifier: "Com.Unit", muted: expected)])
  }

  @Test("Toggle preserves duplicate identities and query order")
  func togglesAreOrdered() throws {
    let result = try parse("finetune://toggle-mute?app=Com.A&APP=Com.B&app=Com.A")
    #expect(
      result.commands == [
        .toggleMuted(identifier: "Com.A"), .toggleMuted(identifier: "Com.B"),
        .toggleMuted(identifier: "Com.A"),
      ])
  }

  @Test(
    "URL step is a signed fixed slider delta",
    arguments: [
      ("up", Float(0.05)), ("UP", 0.05), ("%2B", 0.05),
      ("down", -0.05), ("DOWN", -0.05), ("-", -0.05),
    ])
  func sliderStep(value: String, expected: Float) throws {
    let result = try parse("finetune://step-volume?app=Com.Unit&direction=\(value)")
    #expect(result.commands == [.stepSlider(identifier: "Com.Unit", delta: expected)])
  }

  @Test("Single-target actions use the first exact-case query key")
  func firstExactKeys() throws {
    let device = try parse(
      "finetune://set-device?app=Com.First&app=Com.Second&device=UID.A&device=UID.B")
    #expect(device.commands == [.setOutputDevice(identifier: "Com.First", uid: "UID.A")])
    let step = try parse(
      "finetune://step-volume?APP=Wrong&app=Com.First&direction=down&direction=up")
    #expect(step.commands == [.stepSlider(identifier: "Com.First", delta: -0.05)])
    #expect(try parse("finetune://set-device?APP=Wrong&device=UID.A").commands.isEmpty)
  }

  @Test("Explicit reset never becomes all-active and leaves command meaning narrow")
  func explicitResetTargets() throws {
    let result = try parse("finetune://reset?app=Com.A&APP=Com.B&app=Com.A")
    #expect(
      result.commands == [
        .resetGainAndMute(identifier: "Com.A"), .resetGainAndMute(identifier: "Com.B"),
        .resetGainAndMute(identifier: "Com.A"),
      ])
    #expect(
      try parse("finetune://reset?unrelated=1").commands == [.resetGainAndMute(identifier: nil)])
  }

  @Test("Percent-decoded identifiers are not trimmed or lowercased")
  func exactIdentityValues() throws {
    let result = try parse("finetune://set-volumes?app=%20Com.Mixed%2BID%20&volume=50")
    #expect(result.commands == [.setGain(identifier: " Com.Mixed+ID ", gain: 0.5)])
  }

  @Test(
    "Both ordered-pair grammars match an independently indexed model",
    arguments: ["set-volumes", "set-mute"])
  func boundedPairGrammar(action: String) throws {
    // 4 symbols, lengths 0...4: 341 traces per action, not 682 Swift Testing invocations.
    var traces: [[Int]] = [[]]
    var frontier: [[Int]] = [[]]
    for _ in 0..<4 {
      frontier = frontier.flatMap { prefix in (0..<4).map { prefix + [$0] } }
      traces += frontier
    }
    for trace in traces {
      var components = URLComponents()
      components.scheme = "finetune"
      components.host = action
      components.queryItems = trace.map { token in
        if token < 2 {
          return URLQueryItem(name: "app", value: token == 0 ? "Com.A" : "com.B")
        }
        return URLQueryItem(
          name: action == "set-volumes" ? "volume" : "muted",
          value: token == 2 ? (action == "set-volumes" ? "25" : "yes") : "invalid")
      }
      var expected: [AudioCommand] = []
      for index in trace.indices where trace[index] == 2 {
        // A value can use only an app appearing after the previous value, valid or invalid.
        let lastValue = trace[..<index].lastIndex(where: { $0 >= 2 })
        let start = lastValue.map { $0 + 1 } ?? 0
        if let appIndex = (start..<index).last(where: { trace[$0] < 2 }) {
          let identifier = trace[appIndex] == 0 ? "Com.A" : "com.B"
          expected.append(
            action == "set-volumes"
              ? .setGain(identifier: identifier, gain: 0.25)
              : .setMuted(identifier: identifier, muted: true))
        }
      }
      let result = URLAutomationParser.parse(try #require(components.url))
      #expect(result.commands == expected, "Pair grammar trace: \(trace)")
    }
  }
}
