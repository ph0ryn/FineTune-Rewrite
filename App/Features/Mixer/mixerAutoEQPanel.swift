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
  @State private var highlightedID: String?
  @FocusState private var searchFocused: Bool
  @Environment(\.dismiss) private var dismiss

  private var bindings: MixerProfileBindings {
    MixerProfileBindings(deviceUID: deviceUID, interface: interface)
  }

  var body: some View {
    let current = interface.read(deviceUID)
    let search = interface.search(query, favoritesOnly)
    let results = search.entries
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
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
          Text(bindings.selectionLabel).font(DesignTokens.Typography.cardProfileName)
            .lineLimit(2).help(bindings.selectionLabel)
          if let detail = current.profileDetail {
            Text(detail).font(DesignTokens.Typography.cardSource).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let selection = current.selection {
          favoriteButton(id: selection.profileID, name: bindings.selectionLabel, current: current)
        }
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
          .focused($searchFocused).accessibilityLabel("Search headphone profiles")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
        }
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
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if query.isEmpty && !results.isEmpty {
              Text("FAVORITES").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(results) { profile in
              HStack {
                Button {
                  bindings.choose(profile)
                } label: {
                  VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(profile.name).font(DesignTokens.Typography.cardProfileName)
                    if !profile.detail.isEmpty {
                      Text(profile.detail).font(DesignTokens.Typography.cardSource)
                        .foregroundStyle(.secondary)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                favoriteButton(id: profile.id, name: profile.name, current: current)
                if profile.id == current.selection?.profileID {
                  Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Selected profile")
                }
              }
              .padding(.vertical, DesignTokens.Spacing.xs)
              .background(highlightedID == profile.id ? Color.accentColor.opacity(0.12) : .clear)
              .id(profile.id)
            }
          }
        }
        .frame(maxHeight: 260)
        .onChange(of: highlightedID) { _, id in
          if let id { proxy.scrollTo(id, anchor: .center) }
        }
      }
      if !query.isEmpty && !results.isEmpty {
        Text(
          search.totalCount > results.count
            ? "Showing \(results.count) of \(search.totalCount) results"
            : "\(search.totalCount) results"
        )
        .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Toggle("Apply preamp", isOn: bindings.preampEnabled)
          .help("Apply the profile's preamp to reduce clipping")
          .toggleStyle(.checkbox).font(DesignTokens.Typography.pickerText)
        Spacer()
        Button("Import ParametricEQ.txt…") { importing = true }.controlSize(.small)
      }
      if let importError {
        Text(importError).font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 380)
    .onAppear { searchFocused = true }
    .onChange(of: query) { _, _ in highlightedID = nil }
    .onChange(of: favoritesOnly) { _, _ in highlightedID = nil }
    .onKeyPress(.downArrow) {
      moveHighlight(1, in: results)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveHighlight(-1, in: results)
      return .handled
    }
    .onKeyPress(.return) {
      if let profile = results.first(where: { $0.id == highlightedID }) { bindings.choose(profile) }
      return .handled
    }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
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

  private func moveHighlight(_ direction: Int, in results: [MixerProfileChoice]) {
    guard !results.isEmpty else { return }
    if let index = results.firstIndex(where: { $0.id == highlightedID }) {
      let next = index + direction
      if results.indices.contains(next) { highlightedID = results[next].id }
    } else {
      highlightedID = direction > 0 ? results.first?.id : results.last?.id
    }
  }

  private func favoriteButton(id: String, name: String, current: MixerProfilePresentation)
    -> some View
  {
    Button {
      bindings.toggleFavorite(id)
    } label: {
      Image(systemName: current.favoriteIDs.contains(id) ? "star.fill" : "star")
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(current.favoriteIDs.contains(id) ? "Unfavorite" : "Favorite") \(name)")
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
