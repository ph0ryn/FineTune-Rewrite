import AppKit

/// Installed-app artwork only. Construction and rendering never query workspace metadata.
@MainActor
final class RootApplicationIconCache {
  private let resolve: (String) -> NSImage?
  private var loaded: Set<String> = []
  private var images: [String: NSImage] = [:]

  init(resolve: @escaping (String) -> NSImage?) { self.resolve = resolve }

  func prime(bundleIDs: Set<String>) {
    for bundleID in bundleIDs where loaded.insert(bundleID).inserted {
      images[bundleID] = resolve(bundleID)
    }
  }

  func icon(for bundleID: String?) -> NSImage? {
    bundleID.flatMap { images[$0] }
  }
}
