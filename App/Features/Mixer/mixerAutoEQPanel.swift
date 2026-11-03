import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MixerAutoEQPanel: View {
  let deviceUID: String
  let deviceName: String
  let interface: MixerProfileInterface
  @State private var query = ""
  @State private var favoritesOnly = false
  @State private var importing = false
  @State private var importError: String?

  private var bindings: MixerProfileBindings {
    MixerProfileBindings(deviceUID: deviceUID, interface: interface)
  }

  var body: some View {
    let current = interface.read(deviceUID)
    let results = interface.search(query, favoritesOnly)
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          Text("Headphone Correction").font(DesignTokens.Typography.cardHeader)
          Text(deviceName).font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
        }
        Spacer()
        Toggle("Enable", isOn: bindings.enabled).toggleStyle(.switch).controlSize(.mini)
          .disabled(current.selection == nil)
      }
      HStack {
        Text(bindings.selectionLabel).font(DesignTokens.Typography.cardProfileName)
          .lineLimit(2).help(bindings.selectionLabel)
        Spacer()
        if current.isResolving { ProgressView().controlSize(.small) }
        Button("None", action: bindings.clear).controlSize(.small)
      }
      if current.isMissing {
        Text("The selected profile is not cached. Your selection is kept.")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
      if let error = current.selectionError {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
      HStack(spacing: DesignTokens.Spacing.sm) {
        TextField("Search headphones", text: $query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Search headphone profiles")
        Toggle(isOn: $favoritesOnly) {
          Image(systemName: favoritesOnly ? "star.fill" : "star")
        }
        .toggleStyle(.button).help("Show favorite profiles")
        .accessibilityLabel("Favorite profiles only")
      }
      catalogStatus(current.catalogState)
      if results.isEmpty && current.catalogState == .ready {
        Text(
          query.isEmpty
            ? (favoritesOnly
              ? "No favorite profiles." : "Search for your headphones, or import a profile.")
            : (favoritesOnly ? "No matching favorite profiles." : "No matching profiles.")
        )
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          ForEach(results) { profile in
            HStack {
              Button {
                bindings.choose(profile)
              } label: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                  Text(profile.name).font(DesignTokens.Typography.cardProfileName)
                  if !profile.detail.isEmpty {
                    Text(profile.detail).font(DesignTokens.Typography.cardSource).foregroundStyle(
                      .secondary)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Button {
                bindings.toggleFavorite(profile.id)
              } label: {
                Image(systemName: current.favoriteIDs.contains(profile.id) ? "star.fill" : "star")
              }
              .buttonStyle(.plain)
              .accessibilityLabel(
                "\(current.favoriteIDs.contains(profile.id) ? "Unfavorite" : "Favorite") \(profile.name)"
              )
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
          }
        }
      }
      .frame(maxHeight: 260)
      Divider()
      HStack {
        Toggle("Apply preamp", isOn: bindings.preampEnabled)
          .help("Apply the profile's preamp to reduce clipping")
          .toggleStyle(.checkbox).font(DesignTokens.Typography.pickerText)
        Spacer()
        Button("Import…") { importing = true }.controlSize(.small)
      }
      if let importError {
        Text(importError).font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 380)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
      switch result {
      case .success(let url):
        importError = nil
        bindings.importFile(url)
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          importError = error.localizedDescription
        }
      }
    }
  }

  @ViewBuilder private func catalogStatus(_ state: MixerProfileCatalogState) -> some View {
    switch state {
    case .notLoaded:
      Text("Headphone profiles have not loaded yet.")
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
    case .loading:
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading profiles…")
      }
      .font(DesignTokens.Typography.rowDescription)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
    case .ready: EmptyView()
    }
  }
}
