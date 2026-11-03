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

  nonisolated static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
    VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
  }

  nonisolated static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
    VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
  }

  nonisolated static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
    profileName.map { isEnabled ? $0 : "\($0) (off)" }
  }

  private var effectiveTier: VolumeControlTier { isInput ? .hardware : volumeBackend }

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
      Button(action: onSetDefault) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          if let icon = device.icon {
            Image(nsImage: icon).resizable().frame(width: 24, height: 24)
          } else {
            Image(systemName: isInput ? "mic" : "hifispeaker").frame(width: 24, height: 24)
          }
          Text(device.name).font(DesignTokens.Typography.rowName).lineLimit(1).help(device.name)
          if isDefault { Image(systemName: "checkmark") }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isInput ? "Use \(device.name) as default input" : "Use \(device.name) as default output")
      Spacer(minLength: 0)
      Button(action: onMuteToggle) {
        Image(
          systemName: isMuted.map { $0 ? "speaker.slash.fill" : "speaker.wave.2.fill" }
            ?? "questionmark.circle")
      }
      .buttonStyle(.plain)
      .disabled(!canSetMute || isMuted == nil)
      .accessibilityLabel(
        isMuted.map { $0 ? "Unmute \(device.name)" : "Mute \(device.name)" }
          ?? "Mute control unavailable for \(device.name)")
      if let slider {
        Slider(value: slider, in: 0...1)
          .frame(minWidth: 80, maxWidth: 160)
          .scrollWheelStep(slider, in: 0...1)
          .accessibilityLabel("\(device.name) volume")
      } else {
        Text(volume == nil ? "Unavailable" : "Read-only")
          .font(DesignTokens.Typography.caption)
          .foregroundStyle(DesignTokens.Colors.textSecondary)
          .frame(minWidth: 80, maxWidth: 160)
          .accessibilityLabel(
            "\(device.name) volume \(volume == nil ? "unavailable" : "read-only")")
      }
      Text(
        volume.map {
          "\(Int((Self.volumeToSlider($0, backend: effectiveTier) * 100).rounded()))%"
        } ?? "—"
      )
      .font(DesignTokens.Typography.percentage)
      .frame(width: 36, alignment: .trailing)
      .accessibilityHidden(volume == nil)
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
  }
}
