import AppKit

@main
@MainActor
struct FineTuneApp {
  static func main() {
    let application = NSApplication.shared
    let host = ApplicationHost()
    application.delegate = host
    application.setActivationPolicy(.accessory)
    application.run()
    withExtendedLifetime(host) {}
  }
}
