import FineTuneDomain
import FineTunePlatform
import SwiftUI

/// A presentation row: all device mutations are explicit actions supplied by the composition root.
struct DeviceRow: View {
  let device: AudioDevice
  let isDefault: Bool
  let volume: Float?
  let isMuted: Bool?
  var volumeBackend: VolumeControlTier = .hardware
  var canSetVolume = true
  var canSetMute = true
  var isInput = false
  let onSetDefault: () -> Void
  let onVolumeChange: (Float) -> Void
  let onMuteToggle: () -> Void
  var autoEQSubtitle: String? = nil

  nonisolated static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
    VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
  }

  nonisolated static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
    VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
  }

  nonisolated static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
    profileName.map { isEnabled ? $0 : "\($0) (off)" }
  }

  enum MuteIntent: Equatable {
    case setVolume(Float)
    case setMuted(Bool)
  }

  nonisolated static func displayedPercentage(_ volume: Float, backend: VolumeControlTier) -> Int {
    Int((volumeToSlider(volume, backend: backend) * 100).rounded())
  }

  /// A UI click intent, not a replacement for the observed mute bit or Common's raw mute operation.
  nonisolated static func muteToggleIntent(
    volume: Float?, isMuted: Bool?, backend: VolumeControlTier, canSetVolume: Bool, canSetMute: Bool
  ) -> MuteIntent? {
    if let volume, displayedPercentage(volume, backend: backend) == 0 {
      guard canSetVolume, isMuted != true || canSetMute else { return nil }
      return .setVolume(sliderToVolume(0.5, backend: backend))
    }
    guard canSetMute, let isMuted else { return nil }
    return .setMuted(!isMuted)
  }

  private var effectiveTier: VolumeControlTier { isInput ? .hardware : volumeBackend }

  var displayedPercentage: Int? {
    volume.map { Self.displayedPercentage($0, backend: effectiveTier) }
  }

  var displayedMuteState: Bool? {
    if displayedPercentage == 0 { return true }
    return isMuted
  }

  var canToggleMute: Bool {
    Self.muteToggleIntent(
      volume: volume, isMuted: isMuted, backend: effectiveTier,
      canSetVolume: canSetVolume, canSetMute: canSetMute) != nil
  }

  private var muteAccessibilityLabel: String {
    guard canToggleMute, let muted = displayedMuteState else {
      return "Mute control unavailable for \(device.name)"
    }
    return muted ? "Unmute \(device.name)" : "Mute \(device.name)"
  }

  /// This is the same binding used by the actual slider; missing/read-only values have no setter.
  var slider: Binding<Double>? {
    guard canSetVolume, let volume else { return nil }
    return Binding(
      get: { Self.volumeToSlider(volume, backend: effectiveTier) },
      set: { onVolumeChange(Self.sliderToVolume($0, backend: effectiveTier)) }
    )
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      // Only the name column flexes; every device keeps the same trailing control columns.
      Button(action: selectIfNeeded) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          DeviceBadge(
            icon: device.icon, isSelected: isDefault,
            fallbackSymbol: isInput ? "mic" : "speaker.wave.2.fill")
          VStack(alignment: .leading, spacing: 1) {
            Text(device.name).font(DesignTokens.Typography.rowName).lineLimit(1).help(device.name)
            if let autoEQSubtitle {
              Text(autoEQSubtitle).font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary).lineLimit(1).help(autoEQSubtitle)
            }
          }
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
          Image(systemName: "checkmark")
            .frame(width: DesignTokens.Dimensions.minTouchTarget)
            .opacity(isDefault ? 1 : 0).accessibilityHidden(!isDefault)
        }
      }
      .buttonStyle(.plain)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(
        isInput ? "Use \(device.name) as default input" : "Use \(device.name) as default output"
      )
      .accessibilityAddTraits(isDefault ? .isSelected : [])
      Button(action: onMuteToggle) {
        Image(
          systemName: displayedMuteState.map {
            isInput
              ? ($0 ? "mic.slash.fill" : "mic.fill")
              : ($0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
          } ?? "questionmark.circle")
      }
      .buttonStyle(.plain)
      .frame(width: DesignTokens.Dimensions.minTouchTarget)
      .disabled(!canToggleMute)
      .accessibilityLabel(muteAccessibilityLabel)
      if let slider {
        MixerVolumeSlider(
          value: slider, label: "\(device.name) volume", isDimmed: displayedMuteState == true
        )
        .frame(width: DesignTokens.Dimensions.sliderWidth)
        .scrollWheelStep(slider, in: 0...1)
      } else {
        Text(volume == nil ? "Unavailable" : "Read-only")
          .font(DesignTokens.Typography.caption)
          .foregroundStyle(DesignTokens.Colors.textSecondary)
          .frame(width: DesignTokens.Dimensions.sliderWidth)
          .accessibilityLabel(
            "\(device.name) volume \(volume == nil ? "unavailable" : "read-only")")
      }
      if let slider {
        VolumePercentageField(
          value: slider, range: 0...100, label: "\(device.name) volume percentage")
      } else {
        Text(displayedPercentage.map { "\($0)%" } ?? "—")
          .font(DesignTokens.Typography.percentage)
          .frame(width: DesignTokens.Dimensions.percentageWidth, alignment: .trailing)
          .accessibilityHidden(volume == nil)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
    .contentShape(Rectangle())
    .onTapGesture(perform: selectIfNeeded)
  }

  private func selectIfNeeded() {
    if !isDefault { onSetDefault() }
  }
}
