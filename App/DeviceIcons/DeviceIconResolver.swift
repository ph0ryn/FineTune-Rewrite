import AppKit

enum DeviceIconResolver {
  static func displayIcon(
    overrideSymbol: String?, automatic: NSImage?, deviceName: String
  ) -> NSImage? {
    guard let overrideSymbol,
      let image = NSImage(systemSymbolName: overrideSymbol, accessibilityDescription: deviceName)
    else { return automatic }
    return image
  }
}
