// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// URL grammar derived from FineTune Utilities/URLHandler.swift.
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
import Foundation

public struct URLAutomationDiagnostic: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case unsupportedScheme, unsupportedAction, missingParameter, invalidValue, orphanedValue
  }
  public let kind: Kind
  public let parameter: String
  public let value: String?
}

public struct URLAutomationPlan: Equatable, Sendable {
  public let commands: [AudioCommand]
  public let diagnostics: [URLAutomationDiagnostic]
}

/// The pinned handler's six URL grammars, normalized directly into the common command boundary.
/// Empty write targets and explicit nil-only reset targets are rejected as approved safety differences.
public enum URLAutomationParser {
  public static func parse(_ url: URL) -> URLAutomationPlan {
    guard url.scheme == "finetune" else {
      return URLAutomationPlan(
        commands: [],
        diagnostics: [
          URLAutomationDiagnostic(kind: .unsupportedScheme, parameter: "scheme", value: url.scheme)
        ])
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    var commands: [AudioCommand] = []
    var diagnostics: [URLAutomationDiagnostic] = []
    switch url.host {
    case "set-volumes":
      return parsePairs(items, valueKey: "volume") { identifier, raw in
        guard let percent = Int(raw), (0...100).contains(percent) else { return nil }
        return .setGain(identifier: identifier, gain: Float(percent) / 100)
      }
    case "set-mute":
      return parsePairs(items, valueKey: "muted") { identifier, raw in
        guard let muted = parseBool(raw) else { return nil }
        return .setMuted(identifier: identifier, muted: muted)
      }
    case "toggle-mute":
      let identifiers = appIdentifiers(items, diagnostics: &diagnostics)
      commands = identifiers.map { .toggleMuted(identifier: $0) }
      if commands.isEmpty && diagnostics.isEmpty {
        diagnostics.append(
          URLAutomationDiagnostic(kind: .missingParameter, parameter: "app", value: nil))
      }
    case "step-volume":
      if let identifier = required("app", items: items, diagnostics: &diagnostics),
        let raw = required("direction", items: items, diagnostics: &diagnostics)
      {
        let delta: Float?
        switch raw.lowercased() {
        case "up", "+": delta = 0.05
        case "down", "-": delta = -0.05
        default: delta = nil
        }
        if let delta {
          commands.append(.stepSlider(identifier: identifier, delta: delta))
        } else {
          diagnostics.append(
            URLAutomationDiagnostic(kind: .invalidValue, parameter: "direction", value: raw))
        }
      }
    case "set-device":
      if let identifier = required("app", items: items, diagnostics: &diagnostics),
        let uid = required("device", items: items, diagnostics: &diagnostics)
      {
        commands.append(.setOutputDevice(identifier: identifier, uid: uid))
      }
    case "reset":
      if items.contains(where: { $0.name.lowercased() == "app" }) {
        commands = appIdentifiers(items, diagnostics: &diagnostics)
          .map { .resetGainAndMute(identifier: $0) }
      } else {
        commands = [.resetGainAndMute(identifier: nil)]
      }
    default:
      diagnostics.append(
        URLAutomationDiagnostic(kind: .unsupportedAction, parameter: "host", value: url.host))
    }
    return URLAutomationPlan(commands: commands, diagnostics: diagnostics)
  }

  private static func parsePairs(
    _ items: [URLQueryItem], valueKey: String,
    makeCommand: (String, String) -> AudioCommand?
  ) -> URLAutomationPlan {
    var pending: String?
    var commands: [AudioCommand] = []
    var diagnostics: [URLAutomationDiagnostic] = []
    for item in items {
      switch item.name.lowercased() {
      case "app":
        pending = item.value
        if pending == nil || pending?.isEmpty == true {
          pending = nil
          diagnostics.append(
            URLAutomationDiagnostic(kind: .invalidValue, parameter: "app", value: item.value))
        }
      case valueKey:
        guard let identifier = pending else {
          diagnostics.append(
            URLAutomationDiagnostic(kind: .orphanedValue, parameter: valueKey, value: item.value))
          continue
        }
        // A value consumes its app even when nil, malformed or out of range.
        pending = nil
        guard let raw = item.value, let command = makeCommand(identifier, raw) else {
          diagnostics.append(
            URLAutomationDiagnostic(kind: .invalidValue, parameter: valueKey, value: item.value))
          continue
        }
        commands.append(command)
      default: continue
      }
    }
    if let pending {
      diagnostics.append(
        URLAutomationDiagnostic(kind: .missingParameter, parameter: valueKey, value: pending))
    }
    if commands.isEmpty && diagnostics.isEmpty {
      diagnostics.append(
        URLAutomationDiagnostic(kind: .missingParameter, parameter: "app/\(valueKey)", value: nil))
    }
    return URLAutomationPlan(commands: commands, diagnostics: diagnostics)
  }

  private static func required(
    _ key: String, items: [URLQueryItem], diagnostics: inout [URLAutomationDiagnostic]
  ) -> String? {
    guard let item = items.first(where: { $0.name == key }) else {
      diagnostics.append(
        URLAutomationDiagnostic(kind: .missingParameter, parameter: key, value: nil))
      return nil
    }
    guard let value = item.value, !value.isEmpty else {
      diagnostics.append(
        URLAutomationDiagnostic(kind: .invalidValue, parameter: key, value: item.value))
      return nil
    }
    return value
  }

  private static func appIdentifiers(
    _ items: [URLQueryItem], diagnostics: inout [URLAutomationDiagnostic]
  ) -> [String] {
    var identifiers: [String] = []
    for item in items where item.name.lowercased() == "app" {
      guard let value = item.value, !value.isEmpty else {
        diagnostics.append(
          URLAutomationDiagnostic(kind: .invalidValue, parameter: "app", value: item.value))
        continue
      }
      identifiers.append(value)
    }
    return identifiers
  }

  private static func parseBool(_ raw: String) -> Bool? {
    switch raw.lowercased() {
    case "true", "1", "yes": true
    case "false", "0", "no": false
    default: nil
    }
  }
}
