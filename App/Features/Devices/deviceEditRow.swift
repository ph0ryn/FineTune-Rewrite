import AppKit
import FineTuneDomain
import SwiftUI

/// Priority-edit presentation of a device. Volume controls stay in `DeviceRow` so they cannot
/// crowd the device name out of the popup. Reordering is drag-only; no numeric position is shown
/// or typed in this row.
struct DeviceEditRow: View {
  let device: MixerDevicePresentation
  let icon: NSImage?
  let isInput: Bool
  let isHidden: Bool
  let onDragBegin: () -> Void
  let onDragEnd: () -> Void
  let onToggleHidden: () -> Void
  let onSelectIcon: () -> Void
  let onShowDetails: () -> Void

  private var fallbackSymbol: String { isInput ? "mic" : "speaker.wave.2" }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      MoveOnlyDragHandle(
        uid: device.id, label: device.device.name,
        onBegin: onDragBegin, onEnd: onDragEnd
      )
      .frame(width: 16, height: DesignTokens.Dimensions.rowContentHeight)
      .accessibilityLabel("Drag to reorder \(device.device.name)")

      Button(action: onSelectIcon) {
        Group {
          if let icon {
            Image(nsImage: icon).resizable().scaledToFit()
          } else {
            Image(systemName: fallbackSymbol)
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: DesignTokens.Dimensions.iconSize, height: DesignTokens.Dimensions.iconSize)
      }
      .buttonStyle(.plain)
      .help("Change icon")
      .accessibilityLabel("Icon for \(device.device.name)")

      Button(action: onShowDetails) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Text(device.device.name)
            .font(DesignTokens.Typography.rowName)
            .lineLimit(1)
            .layoutPriority(1)
            .help(device.device.uid)
          if device.isDefault {
            Text("DEFAULT")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(DesignTokens.Colors.textSecondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(DesignTokens.Colors.glassFillStrong))
          }
          Spacer(minLength: 0)
        }
      }
      .buttonStyle(.plain)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Inspect \(device.device.name)")

      Button(action: onToggleHidden) {
        Image(systemName: isHidden ? "eye.slash" : "eye")
          .font(.system(size: 11))
          .foregroundStyle(
            device.isDefault
              ? DesignTokens.Colors.textTertiary.opacity(0.4)
              : (isHidden
                ? DesignTokens.Colors.mutedIndicator
                : DesignTokens.Colors.textTertiary)
          )
          .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(device.isDefault)
      .help(device.isDefault ? "The default device cannot be hidden" : "Toggle visibility")
      .accessibilityLabel("\(isHidden ? "Show" : "Hide") \(device.device.name)")

      Button(action: onShowDetails) {
        Image(systemName: "info.circle")
          .font(.system(size: 12))
          .symbolRenderingMode(.hierarchical)
          .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Details for \(device.device.name)")
    }
    .frame(height: DesignTokens.Dimensions.rowContentHeight)
    .opacity(isHidden ? 0.5 : 1)
  }
}
