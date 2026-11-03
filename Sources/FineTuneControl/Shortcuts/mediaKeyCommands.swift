import FineTuneDomain

public enum MediaKeyEvent: Equatable, Sendable {
  case volumeUp(isRepeat: Bool)
  case volumeDown(isRepeat: Bool)
  case muteToggle
}

public protocol MediaKeyEventDecoding: Sendable {
  func decode(data1: Int) -> MediaKeyEvent?
}

@MainActor
public protocol AccessibilityTrustProviding: AnyObject {
  var isTrusted: Bool { get }
  func refresh()
}

/// A pure change plan. UI and device adapters consume the same interpreted values.
public struct VolumeKeyChange: Equatable, Sendable {
  public let gain: Float?
  public let mute: Bool?
  public let sliderFraction: Double
  public let displayedMute: Bool
  public let feedbackGain: Float?
}

/// Keeps key interpretation out of AppKit and device-writing adapters.
public struct VolumeKeyPlanner: Sendable {
  private var lastDDCRepeatNanoseconds: UInt64?

  public init() {}

  public mutating func plan(
    event: MediaKeyEvent, tier: VolumeControlTier, currentGain: Float, currentMute: Bool,
    step: VolumeHotkeyStep, nowNanoseconds: UInt64, stepMultiplier: Double = 1
  ) -> VolumeKeyChange? {
    guard stepMultiplier.isFinite, stepMultiplier > 0 else { return nil }
    let slider = VolumeMapping.sliderFraction(forSystemGain: currentGain, tier: tier)
    let direction: Double
    let repeats: Bool
    switch event {
    case .muteToggle:
      return VolumeKeyChange(
        gain: nil, mute: !currentMute, sliderFraction: slider,
        displayedMute: !currentMute, feedbackGain: nil)
    case .volumeUp(let repeatPress):
      direction = 1
      repeats = repeatPress
    case .volumeDown(let repeatPress):
      direction = -1
      repeats = repeatPress
    }

    if tier == .ddc && repeats {
      if let previous = lastDDCRepeatNanoseconds,
        nowNanoseconds &- previous < 80_000_000
      {
        return nil
      }
      lastDDCRepeatNanoseconds = nowNanoseconds
    }

    let next = max(0, min(1, slider + direction * step.sliderDelta * stepMultiplier))
    let silent = next <= 0.001
    let newMute = direction > 0 ? false : silent
    let gain = VolumeMapping.systemGain(forSliderFraction: next, tier: tier)
    return VolumeKeyChange(
      gain: gain, mute: newMute == currentMute ? nil : newMute,
      sliderFraction: next, displayedMute: newMute,
      feedbackGain: tier == .software ? gain : 1)
  }
}
