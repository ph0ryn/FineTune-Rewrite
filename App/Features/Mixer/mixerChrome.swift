import SwiftUI

/// Copy rendered by the header. `MixerHeader` reads these values for its visible text and the
/// accessibility/help labels of its icon-only actions.
struct MixerHeaderCopy: Equatable {
  var dragHint = "Drag or type a number to set priority"
  var reorder = "Reorder devices"
  var doneReordering = "Done reordering"
  var retryAudio = "Retry Audio"
  var settings = "Settings"
  var outputTab = "Output Devices"
  var inputTab = "Input Devices"

  var allStrings: [String] {
    [dragHint, reorder, doneReordering, retryAudio, settings, outputTab, inputTab]
  }
}

/// Copy rendered by the footer button; `MixerFooter` reads these values directly.
struct MixerFooterCopy: Equatable {
  var quit = "Quit"
  var shortcut = "⌘Q"
  var accessibilityLabel = "Quit FineTune-Rewrite"
  var help = "Quit FineTune-Rewrite (⌘Q)"
}

/// Compact original controls, independent of device services and application lifecycle.
struct MixerHeader: View {
  @Binding var scope: MixerDeviceScope
  let isEditing: Bool
  let outputName: String
  let inputName: String
  let edit: () -> Void
  let retryAudio: () -> Void
  let settings: () -> Void
  var copy = MixerHeaderCopy()

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
      deviceTabs
      Spacer(minLength: 0)
      if isEditing {
        Text(copy.dragHint)
          .font(DesignTokens.Typography.rowDescription)
          .foregroundStyle(DesignTokens.Colors.textSecondary)
      } else {
        defaultDevicesStatus
      }
      Spacer(minLength: 0)
      Button(
        isEditing ? copy.doneReordering : copy.reorder,
        systemImage: isEditing ? "checkmark" : "pencil", action: edit
      )
      .font(.system(size: 12, weight: isEditing ? .bold : .regular))
      .help(isEditing ? copy.doneReordering : copy.reorder)
      .modifier(HeaderIcon())

      Button(copy.retryAudio, systemImage: "arrow.clockwise", action: retryAudio)
        .font(.system(size: 12))
        .help(copy.retryAudio)
        .modifier(HeaderIcon())

      Button(copy.settings, systemImage: "gearshape.fill", action: settings)
        .font(.system(size: 12))
        .help(copy.settings)
        .modifier(HeaderIcon())
    }
    .padding(.bottom, DesignTokens.Spacing.xs)
  }

  private var deviceTabs: some View {
    HStack(spacing: 2) {
      ForEach(MixerDeviceScope.allCases) { tab in
        Button {
          scope = tab
        } label: {
          Image(systemName: tab == .output ? "speaker.wave.2.fill" : "mic.fill")
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(
              scope == tab ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary
            )
            .frame(width: 26, height: 26)
            .background {
              if scope == tab {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                  .fill(DesignTokens.Colors.glassFillStrong)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab == .output ? copy.outputTab : copy.inputTab)
        .accessibilityAddTraits(scope == tab ? .isSelected : [])
        .help(tab == .output ? copy.outputTab : copy.inputTab)
      }
    }
    .padding(3)
    .fixedSize()
  }

  private var defaultDevicesStatus: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      deviceStatus(outputName, symbol: "speaker.wave.2.fill")
      Text("·")
      deviceStatus(inputName, symbol: "mic.fill")
    }
    .font(DesignTokens.Typography.rowDescription)
    .foregroundStyle(DesignTokens.Colors.textSecondary)
  }

  private func deviceStatus(_ name: String, symbol: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).font(.system(size: 9))
      Text(name).lineLimit(1).truncationMode(.middle)
    }
    .help(name)
  }

  private struct HeaderIcon: ViewModifier {
    func body(content: Content) -> some View {
      content
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .frame(
          minWidth: DesignTokens.Dimensions.minTouchTarget,
          minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
    }
  }
}

struct MixerFooter: View {
  let quit: () -> Void
  var copy = MixerFooterCopy()
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack {
      Spacer()
      Button(action: quit) {
        HStack(spacing: 6) {
          Text(copy.quit)
          Text(copy.shortcut).foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Colors.textSecondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule().strokeBorder(
            isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
            lineWidth: 0.5)
        }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("q", modifiers: .command)
      .accessibilityLabel(copy.accessibilityLabel)
      .help(copy.help)
      .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
      .onHover { isHovered = $0 }
      .animation(reduceMotion ? nil : DesignTokens.Animation.hover, value: isHovered)
    }
  }
}
