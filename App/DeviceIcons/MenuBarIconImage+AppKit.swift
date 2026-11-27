import AppKit

@MainActor
extension MenuBarIconImage {
  static let canvasSize = NSSize(width: 22, height: 18)

  private static var resourceBundle: Bundle {
    #if SWIFT_PACKAGE
      Bundle.module
    #else
      Bundle.main
    #endif
  }

  func nsImage(accessibilityDescription: String = "FineTune-Rewrite") -> NSImage? {
    let source: NSImage?
    switch self {
    case .systemSymbol(let symbol):
      source = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    case .asset(let name):
      source = Self.resourceBundle.image(forResource: name) ?? NSImage(named: name)
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
}
