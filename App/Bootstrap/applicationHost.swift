import AppKit
import Foundation

/// Bridges AppKit events into the one coordinator; no duplicate audio lifecycle lives here.
@MainActor
final class ApplicationHost: NSObject, NSApplicationDelegate {
  private var root: ProductionRoot?
  private var urlAutomation: URLAutomationController?
  private var pendingURLs: [URL] = []
  private var startupTask: Task<Void, Never>?
  private var observations: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false)
      let root = try ProductionRoot(
        directory: support.appendingPathComponent("FineTune-Rewrite", isDirectory: true),
        usageDescription: Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription")
          as? String, quit: { NSApp.terminate(nil) })
      self.root = root
      attachURLAutomation(root.graph.urlAutomation)
      installMenu()
      installLifecycleNotifications(root)
      _ = root.menuBar
      startupTask = Task { await root.lifecycle.start() }
    } catch {
      let alert = NSAlert()
      alert.messageText = "Couldn’t open FineTune Rewrite"
      alert.informativeText = String(describing: error)
      alert.addButton(withTitle: "Quit")
      alert.runModal()
      NSApp.terminate(nil)
    }
  }

  private func installLifecycleNotifications(_ root: ProductionRoot) {
    let center = NSWorkspace.shared.notificationCenter
    let events: [(Notification.Name, LifecycleEvent)] = [
      (NSWorkspace.willSleepNotification, .systemWillSleep),
      (NSWorkspace.didWakeNotification, .systemDidWake),
      (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
      (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
    ]
    for (name, event) in events {
      observations.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak root] _ in
          Task { @MainActor in await root?.lifecycle.handle(event) }
        })
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    root?.refreshAccessibility()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    receiveOpenURLs(urls)
  }

  func receiveOpenURLs(_ urls: [URL]) {
    guard let urlAutomation else {
      pendingURLs.append(contentsOf: urls)
      return
    }
    for url in urls { urlAutomation.handleURL(url) }
    root?.presentation.invalidate()
  }

  func attachURLAutomation(_ automation: URLAutomationController) {
    urlAutomation = automation
    let urls = pendingURLs
    pendingURLs.removeAll()
    receiveOpenURLs(urls)
  }

  func applicationWillTerminate(_ notification: Notification) {
    startupTask?.cancel()
    root?.prepareForTermination()
    removeLifecycleNotifications()
  }

  private func installMenu() {
    let main = NSMenu()
    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "FineTune Rewrite")
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    applicationMenu.addItem(settings)
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(
      NSMenuItem(
        title: "Quit FineTune Rewrite", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    applicationItem.submenu = applicationMenu
    main.addItem(applicationItem)
    NSApp.mainMenu = main
  }

  @objc private func openSettings() { root?.openSettings() }

  private func removeLifecycleNotifications() {
    for observation in observations {
      NSWorkspace.shared.notificationCenter.removeObserver(observation)
    }
    observations.removeAll()
  }

  isolated deinit {
    startupTask?.cancel()
    for observation in observations {
      NSWorkspace.shared.notificationCenter.removeObserver(observation)
    }
  }
}
