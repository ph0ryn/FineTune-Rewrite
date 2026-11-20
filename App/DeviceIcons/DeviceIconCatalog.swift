import FineTuneDomain
import Foundation

/// Ordered, searchable icon choices. The symbol vocabulary is kept compatible with the fixed UI.
enum DeviceIconCatalog {
  struct Entry: Identifiable, Equatable, Sendable {
    let symbol: String
    let keywords: [String]
    var id: String { symbol }
  }

  struct Category: Identifiable, Sendable {
    let name: String
    let entries: [Entry]
    var id: String { name }
  }

  private static func group(_ name: String, _ rows: [(String, String)]) -> Category {
    Category(
      name: name,
      entries: rows.map {
        Entry(symbol: $0.0, keywords: $0.1.components(separatedBy: ","))
      })
  }

  static let categories: [Category] = [
    group(
      "Headphones & Earbuds",
      [
        ("headphones", "headphones,cans,over-ear"),
        ("airpodspro", "airpods,pro,earbuds"),
        ("airpodsmax", "airpods,max,over-ear"),
        ("airpods", "airpods,earbuds"),
        ("airpods.gen3", "airpods,earbuds"),
        ("airpods.gen4", "airpods,earbuds"),
        ("airpod.left", "airpod,left,earbud"),
        ("airpod.right", "airpod,right,earbud"),
        ("airpodspro.chargingcase.wireless.fill", "airpods,case,charging"),
        ("airpods.chargingcase.wireless.fill", "airpods,case,charging"),
        ("earpods", "earpods,wired,apple"),
        ("earbuds", "earbuds,in-ear"),
        ("earbuds.case.fill", "earbuds,case"),
        ("beats.headphones", "beats,headphones"),
        ("beats.earphones", "beats,earphones,earbuds"),
        ("beats.powerbeatspro", "beats,powerbeats,sport"),
        ("beats.powerbeats", "beats,powerbeats,sport"),
        ("beats.studiobuds", "beats,studio,buds"),
        ("beats.solobuds", "beats,solo,buds"),
        ("beats.fitpro", "beats,fit,sport"),
        ("hearingdevice.ear", "hearing,aid,ear"),
      ]),
    group(
      "Speakers",
      [
        ("hifispeaker", "speaker,hifi"),
        ("hifispeaker.fill", "speaker,hifi"),
        ("hifispeaker.2", "speakers,stereo,pair"),
        ("hifispeaker.2.fill", "speakers,stereo,pair"),
        ("homepod.fill", "homepod,speaker"),
        ("homepod.2.fill", "homepod,stereo,pair"),
        ("homepodmini.fill", "homepod,mini,speaker"),
        ("homepodmini.2.fill", "homepod,mini,stereo,pair"),
        ("homepod.and.homepodmini.fill", "homepod,pair,stereo"),
        ("speaker.fill", "speaker"),
        ("speaker.wave.1.fill", "speaker,quiet"),
        ("speaker.wave.2.fill", "speaker,volume"),
        ("speaker.wave.3.fill", "speaker,loud"),
        ("beats.pill", "beats,pill,speaker"),
        ("radio.fill", "radio,boombox"),
        ("tv.and.hifispeaker.fill", "tv,soundbar,home theater"),
        ("hifispeaker.and.appletv.fill", "apple tv,home theater,speaker"),
        ("hifireceiver.fill", "receiver,amp,home theater"),
      ]),
    group(
      "Computers & Displays",
      [
        ("macbook", "macbook,laptop"),
        ("laptopcomputer", "laptop,notebook"),
        ("desktopcomputer", "imac,desktop"),
        ("macstudio.fill", "mac,studio"),
        ("macmini.fill", "mac,mini"),
        ("macpro.gen3.fill", "mac,pro,tower"),
        ("display", "display,monitor,screen"),
        ("display.2", "displays,monitors,dual"),
        ("tv", "tv,television,hdmi"),
        ("tv.fill", "tv,television,hdmi"),
        ("appletv.fill", "apple tv,airplay"),
        ("iphone", "iphone,phone,continuity"),
        ("ipad", "ipad,tablet"),
        ("visionpro", "vision,pro,spatial"),
        ("videoprojector.fill", "projector,beamer,hdmi"),
      ]),
    group(
      "Microphones",
      [
        ("mic", "mic,microphone"),
        ("mic.fill", "mic,microphone"),
        ("music.microphone", "mic,vocal,studio"),
        ("mic.circle.fill", "mic,microphone"),
        ("mic.square.fill", "mic,microphone"),
        ("waveform.and.mic", "mic,voice,recording"),
        ("web.camera.fill", "webcam,camera"),
        ("headset", "headset,boom,gaming,calls"),
      ]),
    group(
      "Connectors & Other",
      [
        ("cable.connector", "cable,jack,aux,3.5mm"),
        ("cable.connector.horizontal", "cable,jack,aux"),
        ("cable.coaxial", "cable,coaxial,spdif"),
        ("bolt.horizontal", "thunderbolt"),
        ("waveform", "waveform,virtual,audio"),
        ("waveform.circle.fill", "waveform,virtual,audio"),
        ("dot.radiowaves.left.and.right", "wireless,signal"),
        ("antenna.radiowaves.left.and.right", "antenna,broadcast"),
        ("airplayaudio", "airplay,audio"),
        ("airplayvideo", "airplay,video"),
        ("gamecontroller.fill", "game,controller,console"),
        ("car.fill", "car,auto"),
        ("car.side.fill", "car,auto"),
        ("guitars.fill", "guitar,instrument,amp"),
        ("pianokeys", "piano,keyboard,midi"),
        ("amplifier", "amp,amplifier,guitar"),
        ("slider.vertical.3", "mixer,faders,interface"),
        ("dial.medium.fill", "knob,gain,interface,amp"),
        ("recordingtape", "tape,recorder,recording"),
        ("megaphone.fill", "megaphone,pa,announcement"),
        ("tuningfork", "tuning,fork,pitch"),
        ("music.note", "music,note"),
        ("opticaldisc.fill", "cd,disc,player"),
      ]),
  ]

  static let allEntries = categories.flatMap(\.entries)

  static func entry(for symbol: String) -> Entry? {
    allEntries.first { $0.symbol == symbol }
  }

  static func matching(_ query: String) -> [Entry] {
    let term = query.trimmingCharacters(in: .whitespaces).lowercased()
    return term.isEmpty
      ? allEntries
      : allEntries.filter {
        ([$0.symbol] + $0.keywords).contains { $0.lowercased().contains(term) }
      }
  }

  static func suggested(forName name: String, transport: TransportType) -> [String] {
    let choices: String
    switch transport {
    case .bluetooth, .bluetoothLE:
      choices =
        "headphones airpodspro airpodsmax airpods.gen3 earbuds beats.headphones hifispeaker.fill headset"
    case .usb:
      choices =
        "headphones mic.fill cable.connector amplifier hifispeaker.fill headset slider.vertical.3"
    case .builtIn:
      choices = "macbook laptopcomputer desktopcomputer hifispeaker mic.fill"
    case .hdmi, .displayPort:
      choices = "tv display tv.and.hifispeaker.fill display.2 videoprojector.fill"
    case .airPlay:
      choices =
        "airplayaudio homepod.fill homepodmini.fill appletv.fill tv.and.hifispeaker.fill homepod.2.fill"
    case .virtual:
      choices = "waveform waveform.circle.fill dot.radiowaves.left.and.right music.note"
    case .thunderbolt:
      choices = "bolt.horizontal amplifier cable.connector hifispeaker.fill"
    case .aggregate:
      choices = "speaker.wave.2.fill hifispeaker.2.fill waveform"
    case .unknown:
      choices = "hifispeaker headphones speaker.wave.2.fill"
    }
    let automatic = DeviceIconSymbol.iconSymbol(forName: name, transport: transport)
    var seen: Set<String> = []
    return ([automatic] + choices.split(separator: " ").map(String.init)).filter {
      seen.insert($0).inserted
    }
  }
}
