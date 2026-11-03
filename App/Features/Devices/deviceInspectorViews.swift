import AppKit
import CoreAudio
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI

@MainActor @Observable
final class DeviceInspectorModel {
  private let device: AudioDevice
  private let transport: TransportType
  private(set) var info: DeviceInspectorInfo?
  private(set) var error: String?

  init(device: AudioDevice, transport: TransportType) {
    self.device = device
    self.transport = transport
  }

  /// Called by the visible inspector, not by constructing a test view or a fixture device.
  func refresh() {
    do {
      let rate = try device.id.readNominalSampleRate()
      info = DeviceInspectorInfo(
        transportLabel: Self.transportLabel(transport), sampleRate: rate,
        availableSampleRates: device.id.readAvailableSampleRates(),
        sampleRateSettable: device.id.isPropertySettable(
          kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal),
        formatLabel: DeviceInspectorInfo.formatPhysicalFormat(device.id.readPhysicalFormat()),
        hogModeOwner: device.id.readHogModeOwner(), uid: device.uid
      )
      error = nil
    } catch {
      self.error = "Unable to read device information: \(error.localizedDescription)"
    }
  }

  func selectSampleRate(_ rate: Double) {
    do {
      try device.id.writeNominalSampleRate(rate)
      refresh()
    } catch {
      self.error = "Unable to change sample rate: \(error.localizedDescription)"
    }
  }

  private static func transportLabel(_ transport: TransportType) -> String {
    switch transport {
    case .builtIn: "Built-in"
    case .usb: "USB"
    case .bluetooth: "Bluetooth"
    case .bluetoothLE: "Bluetooth LE"
    case .airPlay: "AirPlay"
    case .virtual: "Virtual"
    case .thunderbolt: "Thunderbolt"
    case .hdmi: "HDMI"
    case .displayPort: "DisplayPort"
    case .aggregate: "Aggregate"
    case .unknown: "Unknown"
    }
  }
}

@MainActor
struct DeviceInspectorInfoGrid: View {
  let info: DeviceInspectorInfo
  let onSampleRateSelected: (Double) -> Void
  @State private var copied = false

  var body: some View {
    Grid(
      alignment: .leadingFirstTextBaseline, horizontalSpacing: DesignTokens.Spacing.md,
      verticalSpacing: 4
    ) {
      ForEach(Array(InfoGridLayout(info: info).rows.enumerated()), id: \.offset) { _, row in
        GridRow {
          Text(label(for: row)).foregroundStyle(DesignTokens.Colors.textSecondary)
          value(for: row).gridColumnAlignment(.trailing).frame(
            maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .font(DesignTokens.Typography.pickerText)
  }

  private func label(for row: InfoGridLayout.Row) -> String {
    switch row {
    case .transport: "Transport"
    case .sampleRate: "Sample rate"
    case .format: "Format"
    case .deviceID: "Device ID"
    }
  }

  @ViewBuilder private func value(for row: InfoGridLayout.Row) -> some View {
    switch row {
    case .transport(let text), .format(let text): Text(text)
    case .sampleRate(let display, let editable, let options):
      if editable {
        Menu(display) {
          ForEach(options, id: \.self) { rate in
            Button(DeviceInspectorInfo.formatSampleRate(rate)) { onSampleRateSelected(rate) }
          }
        }
        .fixedSize()
        .accessibilityLabel("Sample rate: \(display). Activate to change.")
      } else {
        Text(display)
      }
    case .deviceID(let uid):
      HStack(spacing: 4) {
        Text(uid).lineLimit(1).truncationMode(.middle).help(uid)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(uid, forType: .string)
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Device ID copied" : "Copy device ID")
      }
    }
  }
}

@MainActor
struct DeviceDetailSheet: View {
  let device: AudioDevice
  let transportType: TransportType
  let autoDetectedTier: VolumeControlTier
  let currentOverride: VolumeControlTier?
  let onOverrideChange: (VolumeControlTier?) -> Void
  let onDismiss: () -> Void
  @State private var inspector: DeviceInspectorModel

  init(
    device: AudioDevice, transportType: TransportType, autoDetectedTier: VolumeControlTier,
    currentOverride: VolumeControlTier?, onOverrideChange: @escaping (VolumeControlTier?) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.device = device
    self.transportType = transportType
    self.autoDetectedTier = autoDetectedTier
    self.currentOverride = currentOverride
    self.onOverrideChange = onOverrideChange
    self.onDismiss = onDismiss
    _inspector = State(initialValue: DeviceInspectorModel(device: device, transport: transportType))
  }

  static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool { autoTier != .software }

  /// This is the actual SwiftUI binding, also exercised by rewrite boundary tests.
  var useSoftwareBinding: Binding<Bool> {
    Binding(
      get: { currentOverride == .software },
      set: { onOverrideChange($0 ? .software : nil) }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      if let info = inspector.info {
        DeviceInspectorInfoGrid(info: info, onSampleRateSelected: inspector.selectSampleRate)
        if let owner = DeviceInspectorInfo.formatHogModeOwner(
          info.hogModeOwner,
          processName: NSRunningApplication(processIdentifier: info.hogModeOwner)?.localizedName
        ) {
          Label(owner, systemImage: "lock.fill").font(DesignTokens.Typography.caption)
        }
      }
      if let error = inspector.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(DesignTokens.Typography.caption)
      }
      if Self.shouldShowToggle(autoTier: autoDetectedTier) {
        Divider()
        Toggle("Use FineTune's software volume", isOn: useSoftwareBinding).toggleStyle(.switch)
          .font(DesignTokens.Typography.pickerText)
        Text(
          "Turn on only if the volume slider doesn't work. FineTune remembers this for each device."
        )
        .font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textTertiary)
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(DesignTokens.Colors.recessedBackground, in: RoundedRectangle(cornerRadius: 10))
    .onAppear { inspector.refresh() }
  }
}
