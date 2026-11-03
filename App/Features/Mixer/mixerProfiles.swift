import FineTuneDomain
import Foundation
import SwiftUI

struct MixerProfileChoice: Equatable, Identifiable {
  let id: String
  let name: String
  let detail: String
}

enum MixerProfileCatalogState: Equatable {
  case notLoaded, loading, ready
  case failed(String)
}

struct MixerProfilePresentation {
  var catalogState: MixerProfileCatalogState
  var selection: AutoEQSelection?
  var profileName: String?
  var isMissing: Bool
  var isResolving: Bool
  var selectionError: String?
  var favoriteIDs: Set<String>
  var preampEnabled: Bool
}

/// Required view ports, not another catalog/store. read/search are local observable reads only.
@MainActor
struct MixerProfileInterface {
  let read: (String) -> MixerProfilePresentation
  /// The backing catalog applies favorites before its existing ranking and result limit.
  let search: (String, Bool) -> [MixerProfileChoice]
  /// Explicit user-selected URL; import and selection retain the originating device UID.
  let importProfile: (String, URL, String) -> Void
  let select: (String, AutoEQSelection?) -> Void
  let setFavorite: (String, Bool) -> Void
  let setPreampEnabled: (Bool) -> Void
}

@MainActor
struct MixerProfileBindings {
  let deviceUID: String
  let interface: MixerProfileInterface

  var selectionLabel: String {
    let current = interface.read(deviceUID)
    guard let selection = current.selection else { return "None" }
    let name = current.profileName ?? selection.profileID
    return current.isMissing ? "\(name) (not cached)" : name
  }

  var enabled: Binding<Bool> {
    Binding(
      get: { interface.read(deviceUID).selection?.isEnabled ?? false },
      set: { value in
        // The disabled no-selection control never invents a profile. A stale cleared row is ignored.
        guard var selection = interface.read(deviceUID).selection else { return }
        selection.isEnabled = value
        interface.select(deviceUID, selection)
      })
  }

  var preampEnabled: Binding<Bool> {
    Binding(
      get: { interface.read(deviceUID).preampEnabled },
      set: { interface.setPreampEnabled($0) })
  }

  func choose(_ profile: MixerProfileChoice) {
    interface.select(deviceUID, AutoEQSelection(profileID: profile.id, isEnabled: true))
  }

  func clear() { interface.select(deviceUID, nil) }

  func toggleFavorite(_ id: String) {
    interface.setFavorite(id, !interface.read(deviceUID).favoriteIDs.contains(id))
  }

  func importFile(_ url: URL) {
    interface.importProfile(deviceUID, url, url.deletingPathExtension().lastPathComponent)
  }
}
