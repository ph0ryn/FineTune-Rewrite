/// Converts slider fractions to PCM gain without conflating device scalars with app gain.
public enum VolumeMapping {
  public static func sliderToGain(_ slider: Double) -> Float {
    if slider <= 0 { return 0 }
    let fraction = min(slider, 1)
    return Float(fraction * fraction)
  }

  public static func gainToSlider(_ gain: Float) -> Double {
    if gain <= 0 { return 0 }
    return Double(min(gain, 1).squareRoot())
  }

  public static func sliderFraction(forSystemGain gain: Float, tier: VolumeControlTier) -> Double {
    switch tier {
    case .software:
      gainToSlider(gain)
    case .hardware, .ddc:
      Double(max(0, min(1, gain)))
    }
  }

  public static func systemGain(forSliderFraction fraction: Double, tier: VolumeControlTier)
    -> Float
  {
    switch tier {
    case .software:
      sliderToGain(fraction)
    case .hardware, .ddc:
      Float(max(0, min(1, fraction)))
    }
  }
}

/// A boost is independent of the saved, unboosted app gain and mute state.
public enum BoostLevel: Float, CaseIterable, Codable, Sendable {
  case x1 = 1
  case x2 = 2
  case x3 = 3
  case x4 = 4

  public var label: String {
    switch self {
    case .x1: "1x"
    case .x2: "2x"
    case .x3: "3x"
    case .x4: "4x"
    }
  }

  public var next: BoostLevel {
    switch self {
    case .x1: .x2
    case .x2: .x3
    case .x3: .x4
    case .x4: .x1
    }
  }

  public var isBoosted: Bool { self != .x1 }
}

/// The meaning of a device's volume value, not an OS device handle.
public enum VolumeControlTier: String, Codable, Equatable, Sendable {
  case hardware
  case ddc
  case software
}

public enum DeviceSelectionMode: String, Codable, Equatable, Sendable {
  case single
  case multi
}
