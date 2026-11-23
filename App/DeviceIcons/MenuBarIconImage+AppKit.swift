import AppKit

@MainActor
extension MenuBarIconImage {
  static let canvasSize = NSSize(width: 22, height: 18)

  func nsImage(accessibilityDescription: String = "FineTune-Rewrite") -> NSImage? {
    let source: NSImage?
    switch self {
    case .systemSymbol(let symbol):
      source = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    case .asset("MenuBarIcon"):
      source = Self.defaultGlyph()
    case .asset(let name):
      source = NSImage(named: name)
    }
    guard let source else { return nil }
    let natural = source.size
    let factor = min(
      1, Self.canvasSize.width / natural.width, Self.canvasSize.height / natural.height)
    let size = NSSize(width: natural.width * factor, height: natural.height * factor)
    let origin = NSPoint(
      x: (Self.canvasSize.width - size.width) / 2,
      y: (Self.canvasSize.height - size.height) / 2)
    let rendered = NSImage(size: Self.canvasSize, flipped: false) { _ in
      source.draw(in: NSRect(origin: origin, size: size))
      return true
    }
    rendered.isTemplate = true
    rendered.accessibilityDescription = accessibilityDescription
    return rendered
  }

  /// Independently drawn waveform mark, not a bundled copy of the upstream PDF asset.
  private static func defaultGlyph() -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
      NSColor.black.setStroke()
      let waveform = NSBezierPath()
      waveform.lineWidth = 1.6
      waveform.lineCapStyle = .round
      for (x, height) in [(2.0, 3.0), (5, 9), (8, 14), (11, 7), (14, 3)] {
        waveform.move(to: NSPoint(x: x, y: 8 - height / 2))
        waveform.line(to: NSPoint(x: x, y: 8 + height / 2))
      }
      waveform.move(to: NSPoint(x: 1, y: 8))
      waveform.line(to: NSPoint(x: 15, y: 8))
      waveform.stroke()
      return true
    }
  }
}
