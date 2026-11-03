// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// APO format rules derived from FineTune AutoEQParser.swift.
// Upstream revision: 2285279d36d3f8115c1c2d4aecd904f1bdf96a51
import FineTuneDomain
import Foundation

public struct ProfileParseDiagnostic: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case invalidPreamp, invalidFilter, truncatedFilters }
  public let kind: Kind
  public let line: Int?
}

public struct ParsedAutoEQProfile: Sendable {
  public let profile: AutoEQProfile
  public let diagnostics: [ProfileParseDiagnostic]
}

public enum ParametricEQTextParser {
  public static func parse(
    text: String, name: String, source: AutoEQSource, id: String
  ) throws -> ParsedAutoEQProfile {
    var preamp: Float = 0
    var filters: [AutoEQFilter] = []
    var diagnostics: [ProfileParseDiagnostic] = []
    for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      if trimmed.lowercased().hasPrefix("preamp:") {
        let value = trimmed.components(separatedBy: ":").dropFirst().first?
          .split(whereSeparator: \.isWhitespace).first.flatMap { Float($0) }
        if let value, value.isFinite {
          preamp = max(-30, min(30, value))
        } else {
          preamp = 0
          diagnostics.append(ProfileParseDiagnostic(kind: .invalidPreamp, line: offset + 1))
        }
      } else if trimmed.lowercased().hasPrefix("filter") {
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.contains(where: { $0.uppercased() == "ON" }) else { continue }
        guard let filter = parseFilter(tokens) else {
          diagnostics.append(ProfileParseDiagnostic(kind: .invalidFilter, line: offset + 1))
          continue
        }
        filters.append(filter)
      }
    }
    guard !filters.isEmpty else { throw ProfileRepositoryError.noValidFilters }
    if filters.count > AutoEQProfile.maxFilters {
      filters = Array(filters.prefix(AutoEQProfile.maxFilters))
      diagnostics.append(ProfileParseDiagnostic(kind: .truncatedFilters, line: nil))
    }
    return ParsedAutoEQProfile(
      profile: AutoEQProfile(
        id: id, name: name, source: source, preampDB: preamp, filters: filters),
      diagnostics: diagnostics)
  }

  private static func parseFilter(_ tokens: [String]) -> AutoEQFilter? {
    let types: [String: AutoEQFilter.FilterType] = [
      "PK": .peaking, "PEQ": .peaking, "LS": .lowShelf, "LSC": .lowShelf,
      "HS": .highShelf, "HSC": .highShelf,
    ]
    guard let type = tokens.compactMap({ types[$0.uppercased()] }).first,
      let frequency = value(after: "Fc", tokens: tokens),
      let gain = value(after: "Gain", tokens: tokens),
      let q = value(after: "Q", tokens: tokens),
      frequency.isFinite, gain.isFinite, q.isFinite,
      frequency > 0, q > 0, abs(gain) <= 30
    else { return nil }
    return AutoEQFilter(type: type, frequency: Double(frequency), gainDB: gain, q: Double(q))
  }

  private static func value(after keyword: String, tokens: [String]) -> Float? {
    guard
      let index = tokens.firstIndex(where: {
        $0.caseInsensitiveCompare(keyword) == .orderedSame
      }), index + 1 < tokens.count
    else { return nil }
    return Float(tokens[index + 1])
  }
}
