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
  private let isInput: Bool
  private let reader: any AudioDevicePropertyReading
  private let writer: any AudioDevicePropertyWriting
  private let observer: any AudioDevicePropertyObserving
  private let resolveUID: (String) throws -> AudioDeviceID
  private var observations: [AudioObjectPropertySelector: DevicePropertyObservation] = [:]
  private var observedID: AudioDeviceID?
  private var generation: UInt64 = 0
  private var running = false
  private(set) var info: DeviceInspectorInfo?
  private(set) var error: String?

  init(
    device: AudioDevice, transport: TransportType, isInput: Bool = false,
    reader: any AudioDevicePropertyReading = CoreAudioDevicePropertyReader(),
    writer: any AudioDevicePropertyWriting = CoreAudioDevicePropertyWriter(),
    observer: any AudioDevicePropertyObserving = CoreAudioDevicePropertyObserver(),
    resolveUID: @escaping (String) throws -> AudioDeviceID = {
      try CoreAudioDeviceUIDResolver.resolve(uid: $0)
    }
  ) {
    self.device = device
    self.transport = transport
    self.isInput = isInput
    self.reader = reader
    self.writer = writer
    self.observer = observer
    self.resolveUID = resolveUID
  }

  func start() {
    guard !running else { return }
    running = true
    refresh()
  }

  func stop() {
    running = false
    cancelObservations()
  }

  isolated deinit { for observation in observations.values { observation.cancel() } }

  /// Explicit refresh/start only: constructing an inspector does not query HAL or register listeners.
  func refresh() {
    var resolvedID: AudioDeviceID?
    do {
      let id = try resolveUID(device.uid)
      guard id.isValid else { throw DeviceBackendError.unavailableDevice(device.uid) }
      resolvedID = id
      var failures: [String] = []
      let properties = AudioDeviceInspector(reader: reader) {
        failures.append($0.localizedDescription)
      }
      let rate = try reader.readScalar(
        id, selector: kAudioDevicePropertyNominalSampleRate,
        scope: kAudioObjectPropertyScopeGlobal, initial: Double(0))
      guard rate.isFinite, rate > 0 else {
        throw DeviceBackendError.operationFailed("The device returned an invalid sample rate.")
      }
      info = DeviceInspectorInfo(
        transportLabel: Self.transportLabel(transport), sampleRate: rate,
        availableSampleRates: properties.readAvailableSampleRates(for: id),
        sampleRateSettable: properties.isPropertySettable(
          kAudioDevicePropertyNominalSampleRate, for: id, scope: kAudioObjectPropertyScopeGlobal),
        formatLabel: DeviceInspectorInfo.formatPhysicalFormat(
          properties.readPhysicalFormat(
            for: id,
            scope: isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)),
        hogModeOwner: properties.readHogModeOwner(for: id), uid: device.uid)
      error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    } catch {
      self.error = "Unable to read device information: \(error.localizedDescription)"
    }
    if running {
      if let resolvedID { observeChanges(for: resolvedID) } else { cancelObservations() }
    }
  }

  func selectSampleRate(_ rate: Double) {
    do {
      guard rate.isFinite, rate > 0 else {
        throw DeviceBackendError.operationFailed("Choose a valid sample rate.")
      }
      let id = try resolveUID(device.uid)
      guard id.isValid else { throw DeviceBackendError.unavailableDevice(device.uid) }
      guard
        reader.hasProperty(
          id, selector: kAudioDevicePropertyNominalSampleRate,
          scope: kAudioObjectPropertyScopeGlobal),
        try reader.isPropertySettable(
          id, selector: kAudioDevicePropertyNominalSampleRate,
          scope: kAudioObjectPropertyScopeGlobal)
      else { throw DeviceBackendError.unsupported("Sample rate changes") }
      try writer.writeScalar(
        id, selector: kAudioDevicePropertyNominalSampleRate,
        scope: kAudioObjectPropertyScopeGlobal, value: rate)
      refresh()
    } catch {
      self.error = "Unable to change sample rate: \(error.localizedDescription)"
    }
  }

  private func observeChanges(for id: AudioDeviceID) {
    let selectors = Set(
      [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyHogMode].filter {
        reader.hasProperty(id, selector: $0, scope: kAudioObjectPropertyScopeGlobal)
      })
    guard observedID != id || Set(observations.keys) != selectors else { return }
    cancelObservations()
    observedID = id
    let epoch = generation
    for selector in selectors {
      do {
        observations[selector] = try observer.observe(
          id, selector: selector, scope: kAudioObjectPropertyScopeGlobal
        ) { [weak self] in
          guard let self, self.running, self.generation == epoch, self.observedID == id else {
            return
          }
          self.refresh()
        }
      } catch {
        self.error = "Unable to observe device information: \(error.localizedDescription)"
      }
    }
  }

  private func cancelObservations() {
    generation &+= 1
    for observation in observations.values { observation.cancel() }
    observations.removeAll()
    observedID = nil
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
  let autoDetectedTier: VolumeControlTier?
  let currentOverride: VolumeControlTier?
  let isInput: Bool
  let allowsVolumeOverride: Bool
  let onOverrideChange: ((VolumeControlTier?) -> Void)?
  let onDismiss: () -> Void
  @State private var inspector: DeviceInspectorModel

  init(
    device: AudioDevice, transportType: TransportType, autoDetectedTier: VolumeControlTier?,
    currentOverride: VolumeControlTier?, isInput: Bool = false, allowsVolumeOverride: Bool = true,
    onOverrideChange: ((VolumeControlTier?) -> Void)?, onDismiss: @escaping () -> Void
  ) {
    self.device = device
    self.transportType = transportType
    self.autoDetectedTier = autoDetectedTier
    self.currentOverride = currentOverride
    self.isInput = isInput
    self.allowsVolumeOverride = allowsVolumeOverride
    self.onOverrideChange = onOverrideChange
    self.onDismiss = onDismiss
    _inspector = State(
      initialValue: DeviceInspectorModel(device: device, transport: transportType, isInput: isInput)
    )
  }

  static func shouldShowToggle(
    autoTier: VolumeControlTier?, isInput: Bool = false, allowsVolumeOverride: Bool = true,
    hasOverrideAction: Bool = true
  ) -> Bool {
    guard let autoTier else { return false }
    return !isInput && allowsVolumeOverride && hasOverrideAction && autoTier != .software
  }

  /// This is the actual SwiftUI binding, also exercised by rewrite boundary tests.
  var useSoftwareBinding: Binding<Bool> {
    guard !isInput, allowsVolumeOverride, let onOverrideChange else {
      preconditionFailure("An unavailable volume override cannot expose a binding")
    }
    return Binding(
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
      if !isInput, autoDetectedTier == nil {
        Text("Automatic volume control is unavailable.")
          .font(DesignTokens.Typography.caption)
          .foregroundStyle(DesignTokens.Colors.textSecondary)
      }
      softwareVolumeControls
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(DesignTokens.Colors.recessedBackground, in: RoundedRectangle(cornerRadius: 10))
    .onAppear { inspector.start() }
    .onDisappear { inspector.stop() }
  }

  /// The rendered override controls are independent of the sheet's HAL-observing lifecycle.
  @ViewBuilder var softwareVolumeControls: some View {
    if let autoDetectedTier,
      Self.shouldShowToggle(
        autoTier: autoDetectedTier, isInput: isInput, allowsVolumeOverride: allowsVolumeOverride,
        hasOverrideAction: onOverrideChange != nil)
    {
      Divider()
      HStack(spacing: DesignTokens.Spacing.xs) {
        Text("Auto: \(Self.tierDisplayName(autoDetectedTier))")
          .font(DesignTokens.Typography.caption.weight(.semibold))
          .foregroundStyle(DesignTokens.Colors.textSecondary)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(DesignTokens.Colors.glassFillStrong, in: Capsule())
          .fixedSize()
          .accessibilityLabel(
            "Auto-detected volume control: \(Self.tierDisplayName(autoDetectedTier))")
        Toggle("Use FineTune's software volume", isOn: useSoftwareBinding).toggleStyle(.switch)
          .font(DesignTokens.Typography.pickerText)
      }
      Text(
        "Turn on only if the volume slider doesn't work. FineTune remembers this for each device."
      )
      .font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textTertiary)
    }
  }

  private static func tierDisplayName(_ tier: VolumeControlTier) -> String {
    switch tier {
    case .hardware: "Hardware"
    case .ddc: "DDC"
    case .software: "Software"
    }
  }
}
