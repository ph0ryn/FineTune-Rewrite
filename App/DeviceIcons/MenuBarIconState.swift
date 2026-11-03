import FineTuneDomain

/// Rendering requests are independent of AppKit objects and can be compared before drawing.
enum MenuBarIconImage: Equatable, Sendable {
  case systemSymbol(String)
  case asset(String)
}

enum VolumeBucket: Int, Equatable, Sendable {
  case zero, low, mid, high

  static func bucket(for volume: Float) -> Self {
    guard volume.isFinite else { return .zero }
    if volume >= 0.67 { return .high }
    if volume >= 0.34 { return .mid }
    return volume >= 0.01 ? .low : .zero
  }

  var symbolName: String {
    self == .zero ? "speaker.fill" : "speaker.wave.\(rawValue).fill"
  }
}

enum MenuBarIconState: Equatable, Sendable {
  case speakerVolume(VolumeBucket)
  case speakerMuted
  case device(symbol: String)
  case staticBaseline(MenuBarIconImage)
  case deviceFlash(symbol: String)

  var image: MenuBarIconImage {
    switch self {
    case .speakerVolume(let bucket): .systemSymbol(bucket.symbolName)
    case .speakerMuted: .systemSymbol("speaker.slash.fill")
    case .device(let name), .deviceFlash(let name): .systemSymbol(name)
    case .staticBaseline(let image): image
    }
  }

  static func baseline(
    style: MenuBarIconStyle, volume: Float, muted: Bool,
    deviceSymbol: String = MenuBarIconStyle.device.iconName
  ) -> Self {
    if style == .speaker {
      return muted ? .speakerMuted : .speakerVolume(.bucket(for: volume))
    }
    if style == .device { return .device(symbol: deviceSymbol) }
    return .staticBaseline(
      style.isSystemSymbol ? .systemSymbol(style.iconName) : .asset(style.iconName))
  }
}

extension MenuBarIconStyle {
  var isSystemSymbol: Bool { self != .default }

  var iconName: String {
    switch self {
    case .default: "MenuBarIcon"
    case .speaker: "speaker.wave.2.fill"
    case .device: "headphones"
    case .waveform: "waveform"
    case .equalizer: "slider.vertical.3"
    }
  }
}
