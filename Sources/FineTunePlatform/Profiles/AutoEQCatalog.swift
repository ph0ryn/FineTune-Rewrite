import Foundation

public enum ProfileRepositoryError: Error, Equatable, Sendable {
  case noValidFilters
  case invalidIdentifier(String)
  case invalidRelativePath(String)
  case invalidRoot(String)
  case invalidImportURL(String)
  case invalidUTF8
  case invalidCatalog
  case missingModificationDate
  case unknownProfile(String)
  case notImported(String)
  case httpStatus(Int)
}

public struct AutoEQCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let measuredBy: String
  public let relativePath: String

  public init(id: String, name: String, measuredBy: String, relativePath: String) {
    self.id = id
    self.name = name
    self.measuredBy = measuredBy
    self.relativePath = relativePath
  }
}

public struct AutoEQSearchResult: Sendable {
  public let entries: [AutoEQCatalogEntry]
  public let totalCount: Int
}

public enum AutoEQCatalogParser {
  private static let sourcePriority = [
    "oratory1990", "crinacle", "Rtings", "Innerfidelity", "Super Review", "Headphone.com Legacy",
  ]

  public static func parseIndexMarkdown(_ text: String) -> [AutoEQCatalogEntry] {
    var best: [String: (entry: AutoEQCatalogEntry, priority: Int)] = [:]
    for line in text.components(separatedBy: .newlines) {
      guard let entry = parseLine(line) else { continue }
      let key = entry.name.lowercased()
      let priority = sourcePriority.firstIndex(of: entry.measuredBy) ?? sourcePriority.count
      if let existing = best[key], existing.priority <= priority { continue }
      best[key] = (entry, priority)
    }
    return best.values.map(\.entry).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private static func parseLine(_ line: String) -> AutoEQCatalogEntry? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("- ["), let link = trimmed.range(of: "]("),
      let end = trimmed.range(of: ") by ", options: .backwards),
      link.upperBound <= end.lowerBound
    else { return nil }
    let nameStart = trimmed.index(trimmed.startIndex, offsetBy: 3)
    let name = String(trimmed[nameStart..<link.lowerBound])
    guard !name.isEmpty else { return nil }
    var path = String(trimmed[link.upperBound..<end.lowerBound])
    if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
    let relativePath = path.removingPercentEncoding ?? path
    let sourceAndRig = String(trimmed[end.upperBound...])
    let source: String
    if let rig = sourceAndRig.range(of: " on ") {
      source = String(sourceAndRig[..<rig.lowerBound])
    } else {
      source = sourceAndRig.trimmingCharacters(in: .whitespaces)
    }
    guard !source.isEmpty else { return nil }
    let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return AutoEQCatalogEntry(id: id, name: name, measuredBy: source, relativePath: relativePath)
  }
}

/// A derived metadata index, not a second store of loaded profile/filter values.
public struct AutoEQSearchIndex {
  private let entries: [AutoEQCatalogEntry]
  private let normalizedNames: [String]

  public init(entries: [AutoEQCatalogEntry]) {
    self.entries = entries.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    self.normalizedNames = self.entries.map { Self.normalize($0.name) }
  }

  public func filteredEntries(eligibleIDs: Set<String>? = nil) -> [AutoEQCatalogEntry] {
    guard let eligibleIDs else { return entries }
    return entries.filter { eligibleIDs.contains($0.id) }
  }

  public func search(
    query: String, limit: Int = 50, eligibleIDs: Set<String>? = nil
  ) -> AutoEQSearchResult {
    precondition(limit >= 0)
    guard !query.isEmpty else { return AutoEQSearchResult(entries: [], totalCount: 0) }
    let lowered = query.lowercased()
    let normalized = Self.normalize(query)
    var scores: [(index: Int, score: Int)] = []
    for (index, entry) in entries.enumerated() {
      if let eligibleIDs, !eligibleIDs.contains(entry.id) { continue }
      let score = Self.score(
        query: lowered, normalizedQuery: normalized,
        name: entry.name.lowercased(), normalizedName: normalizedNames[index])
      if score > 0 { scores.append((index, score)) }
    }
    scores.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      return entries[$0.index].name < entries[$1.index].name
    }
    return AutoEQSearchResult(
      entries: scores.prefix(limit).map { entries[$0.index] }, totalCount: scores.count)
  }

  private static func score(
    query: String, normalizedQuery: String, name: String, normalizedName: String
  ) -> Int {
    if name.contains(query) {
      return 100 + (name.hasPrefix(query) ? 50 : 0) + (name == query ? 100 : 0)
        + max(0, 50 - name.count)
    }
    if !normalizedQuery.isEmpty && normalizedName.contains(normalizedQuery) {
      return 50 + (normalizedName.hasPrefix(normalizedQuery) ? 25 : 0)
        + max(0, 25 - normalizedName.count)
    }
    let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else { return 0 }
    var total = 0
    for token in tokens {
      let value = bestTokenMatch(token, name: name)
      if value == 0 { return 0 }
      total += value
    }
    return min(49, total / tokens.count)
  }

  private static func bestTokenMatch(_ token: String, name: String) -> Int {
    if name.contains(token) { return 40 }
    let allowed = token.count <= 4 ? 1 : 2
    var best = 0
    for word in name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
      let distance = editDistance(token, String(word).lowercased())
      if distance <= allowed { best = max(best, max(1, 30 - distance * 10)) }
    }
    return best
  }

  private static func editDistance(_ a: String, _ b: String) -> Int {
    let left = Array(a)
    let right = Array(b)
    if left.isEmpty { return right.count }
    if right.isEmpty { return left.count }
    if abs(left.count - right.count) > 2 { return max(left.count, right.count) }
    var previous = Array(0...right.count)
    var current = Array(repeating: 0, count: right.count + 1)
    for i in 1...left.count {
      current[0] = i
      for j in 1...right.count {
        current[j] =
          left[i - 1] == right[j - 1]
          ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
      }
      swap(&previous, &current)
    }
    return previous[right.count]
  }

  private static func normalize(_ value: String) -> String {
    String(
      String.UnicodeScalarView(
        value.unicodeScalars.filter {
          CharacterSet.alphanumerics.contains($0)
        })
    ).lowercased()
  }
}
