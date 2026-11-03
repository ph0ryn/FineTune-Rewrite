import FineTuneDomain

/// Presentation-only name recognition. No HAL lookup or audio routing is performed here.
enum DeviceIconSymbol {
  private static let outputRules: [(name: String, symbol: String)] = [
    ("AirPods Pro", "airpodspro"), ("AirPods Max", "airpodsmax"),
    ("AirPods", "airpods.gen3"), ("HomePod mini", "homepodmini"),
    ("HomePod", "homepod"), ("Apple TV", "appletv"), ("Beats", "beats.headphones"),
    ("Mac Studio", "macstudio.fill"), ("Mac mini", "macmini.fill"),
    ("MacBook", "macbook"), ("iMac", "desktopcomputer"),
    ("Studio Display", "display"), ("Pro Display XDR", "display"),
  ]

  static func iconSymbol(forName name: String, transport: TransportType) -> String {
    outputRules.first { name.contains($0.name) }?.symbol ?? transport.defaultIconSymbol
  }

  static func inputSymbol(forName name: String, transport: TransportType) -> String {
    let inputRules: [(String, String)] = [
      ("iPhone", "iphone"), ("iPad", "ipad"),
      ("AirPods Pro", "airpodspro"), ("AirPods Max", "airpodsmax"),
      ("AirPods", "airpods.gen3"), ("Beats", "beats.headphones"),
      ("MacBook", "laptopcomputer"), ("Studio Display", "display"),
      ("Pro Display XDR", "display"),
    ]
    return inputRules.first { name.contains($0.0) }?.1
      ?? (transport == .usb ? "cable.connector" : "mic")
  }
}

extension TransportType {
  var defaultIconSymbol: String {
    switch self {
    case .builtIn, .unknown: "hifispeaker"
    case .usb, .bluetooth, .bluetoothLE: "headphones"
    case .airPlay: "airplayaudio"
    case .virtual: "waveform"
    case .thunderbolt: "bolt.horizontal"
    case .hdmi, .displayPort: "tv"
    case .aggregate: "speaker.wave.2"
    }
  }
}
