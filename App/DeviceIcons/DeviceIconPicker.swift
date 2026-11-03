import FineTuneDomain
import SwiftUI

/// Picker content uses presentation inputs so rendering never probes a live audio device.
/// The owner applies selections immediately; nil restores the automatic icon.
struct DeviceIconPicker: View {
  let deviceName: String
  let transport: TransportType
  let automaticSymbol: String
  let automaticIsSymbol: Bool
  let currentOverride: String?
  var suggestedLeadingSymbol: String? = nil
  let onSelect: (String?) -> Void

  @State private var query = ""

  private var highlight: String? {
    Self.highlightSymbol(
      currentOverride: currentOverride, automaticIsSymbol: automaticIsSymbol,
      automaticSymbol: automaticSymbol)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(DesignTokens.Colors.textTertiary)
        TextField("Search icons", text: $query)
          .textFieldStyle(.plain)
          .accessibilityLabel("Search icons")
      }
      .font(.system(size: 12))
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, 5)
      .background(DesignTokens.Colors.recessedBackground, in: RoundedRectangle(cornerRadius: 7))

      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          if query.trimmingCharacters(in: .whitespaces).isEmpty {
            section(
              "Suggested",
              symbols: Self.composeSuggested(
                leading: suggestedLeadingSymbol,
                shared: DeviceIconCatalog.suggested(forName: deviceName, transport: transport)))
            ForEach(DeviceIconCatalog.categories) { category in
              section(category.name, symbols: category.entries.map(\.symbol))
            }
          } else {
            let matches = DeviceIconCatalog.matching(query).map(\.symbol)
            if matches.isEmpty {
              Text("No matching icons")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.md)
            } else {
              grid(matches)
            }
          }
        }
      }
      .frame(height: 300)
      .scrollIndicators(.never)

      Button("Restore Default") { onSelect(nil) }
        .controlSize(.small)
        .disabled(currentOverride == nil)
        .frame(maxWidth: .infinity)
    }
    .padding(DesignTokens.Spacing.md)
    .frame(width: 300)
  }

  private func section(_ title: String, symbols: [String]) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(title)
        .textCase(.uppercase)
        .font(DesignTokens.Typography.sectionHeader)
        .tracking(DesignTokens.Typography.sectionHeaderTracking)
        .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
      grid(symbols)
    }
  }

  private func grid(_ symbols: [String]) -> some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xs), count: 6),
      spacing: DesignTokens.Spacing.xs
    ) {
      ForEach(symbols, id: \.self) { symbol in
        DeviceIconCell(symbol: symbol, selected: symbol == highlight) { onSelect(symbol) }
      }
    }
  }

  nonisolated static func highlightSymbol(
    currentOverride: String?, automaticIsSymbol: Bool, automaticSymbol: String
  ) -> String? {
    currentOverride ?? (automaticIsSymbol ? automaticSymbol : nil)
  }

  nonisolated static func composeSuggested(leading: String?, shared: [String]) -> [String] {
    var seen: Set<String> = []
    return ((leading.map { [$0] } ?? []) + shared).filter { seen.insert($0).inserted }
  }
}

private struct DeviceIconCell: View {
  let symbol: String
  let selected: Bool
  let select: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: select) {
      Image(systemName: symbol)
        .font(.system(size: 15))
        .symbolRenderingMode(.hierarchical)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
          selected
            ? DesignTokens.Colors.glassFillStrong
            : hovered ? DesignTokens.Colors.hoverSurface : .clear,
          in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? DesignTokens.Colors.accentPrimary : .clear, lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(DesignTokens.Animation.hover, value: hovered)
    .help(symbol)
    .accessibilityLabel(DeviceIconCatalog.entry(for: symbol)?.keywords.first?.capitalized ?? symbol)
  }
}
