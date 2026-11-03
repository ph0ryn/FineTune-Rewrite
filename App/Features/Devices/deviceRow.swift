import FineTuneDomain
import FineTunePlatform
import SwiftUI

/// A presentation row: all device mutations are explicit actions supplied by the composition root.
struct DeviceRow: View {
  let device: AudioDevice
  let isDefault: Bool
  let volume: Float
  let isMuted: Bool
  var volumeBackend: VolumeControlTier = .hardware
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

  private var slider: Binding<Double> {
    Binding(
      get: { Self.volumeToSlider(volume, backend: volumeBackend) },
      set: { onVolumeChange(Self.sliderToVolume($0, backend: volumeBackend)) }
    )
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button(action: onSetDefault) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          if let icon = device.icon {
            Image(nsImage: icon).resizable().frame(width: 24, height: 24)
          } else {
            Image(systemName: "hifispeaker").frame(width: 24, height: 24)
          }
          Text(device.name).font(DesignTokens.Typography.rowName).lineLimit(1).help(device.name)
          if isDefault { Image(systemName: "checkmark") }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Use \(device.name) as default output")
      Spacer(minLength: 0)
      Button(action: onMuteToggle) {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isMuted ? "Unmute \(device.name)" : "Mute \(device.name)")
      Slider(value: slider, in: 0...1)
        .frame(minWidth: 80, maxWidth: 160)
        .scrollWheelStep(slider, in: 0...1)
        .accessibilityLabel("\(device.name) volume")
      Text("\(Int((Self.volumeToSlider(volume, backend: volumeBackend) * 100).rounded()))%")
        .font(DesignTokens.Typography.percentage)
        .frame(width: 36, alignment: .trailing)
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
  }
}
