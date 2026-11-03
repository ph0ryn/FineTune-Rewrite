import SwiftUI

@MainActor
struct MixerBluetoothSection: View {
  let read: () -> BluetoothPresentation
  let actions: DeviceSettingsActions

  var body: some View {
    let current = read()
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack {
        Text("BLUETOOTH").font(DesignTokens.Typography.sectionHeader)
          .tracking(DesignTokens.Typography.sectionHeaderTracking)
          .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
        Spacer()
        Button(action: actions.refreshBluetooth) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).accessibilityLabel("Refresh Bluetooth devices")
      }
      if let error = current.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(DesignTokens.Typography.caption).foregroundStyle(.orange)
      }
      if let powered = current.isPoweredOn {
        if powered {
          if current.paired.isEmpty && current.error == nil {
            Text("No paired audio devices.").font(DesignTokens.Typography.rowDescription)
              .foregroundStyle(.secondary)
          }
          ForEach(current.paired) { device in bluetoothRow(device) }
        } else {
          Text("Bluetooth is off.").font(DesignTokens.Typography.rowDescription).foregroundStyle(
            .secondary)
        }
      } else {
        Text("Bluetooth status is unavailable.")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  private func bluetoothRow(_ device: PairedBluetoothPresentation) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack {
        Label(device.name, systemImage: device.iconSymbol).font(DesignTokens.Typography.rowName)
        Spacer()
        switch device.connectionState {
        case .idle, .failed:
          Button(device.connectionState == .failed ? "Try Again" : "Connect") {
            actions.connectBluetooth(device.id)
          }
          .controlSize(.small)
        case .connecting:
          ProgressView().controlSize(.small)
          Text("Connecting…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
        case .waitingForAudioDevice:
          Text("Waiting for audio device…")
            .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
        case .connected:
          Text("Connected").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
        }
      }
      if let error = device.error {
        Text(error).font(DesignTokens.Typography.caption).foregroundStyle(.orange)
      }
    }
  }
}
