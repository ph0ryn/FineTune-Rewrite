import AppKit
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI

/// The App owns presentation resources only; callers supply already interpreted slider fractions.
@MainActor
final class HUDWindowController {
  private let settingsManager: SettingsManager
  private let mediaKeyStatus: MediaKeyStatus
  private let popupVisibility: PopupVisibilityService
  /// Delay seam: production stays continuous; tests release the exact hide deadline.
  private let clock: DeviceBackendClock
  private var panel: NSPanel?
  private(set) var hideTask: Task<Void, Never>?
  private var lastStyle: HUDStyle = .tahoe
  private var soundSettingsObserver: NSObjectProtocol?
  private var swallowedAt: ContinuousClock.Instant?

  var volumeWriter: ((Double) -> Void)?
  var hideDelayOverride: Duration?
  var frameProvider: () -> NSRect? = {
    NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
  }
  var fullscreenProvider: @MainActor () -> Bool = HUDWindowController.foregroundIsFullscreen
  private(set) var showCallCount = 0
  private(set) var showDidUpdatePanel = false
  var isVisible: Bool { panel?.isVisible ?? false }

  init(
    settingsManager: SettingsManager, mediaKeyStatus: MediaKeyStatus,
    popupVisibility: PopupVisibilityService, clock: DeviceBackendClock = .continuous
  ) {
    self.settingsManager = settingsManager
    self.mediaKeyStatus = mediaKeyStatus
    self.popupVisibility = popupVisibility
    self.clock = clock
    soundSettingsObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.sound.settingsChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.soundSettingsChanged() }
    }
  }

  isolated deinit {
    hideTask?.cancel()
    if let soundSettingsObserver {
      DistributedNotificationCenter.default().removeObserver(soundSettingsObserver)
    }
    panel?.orderOut(nil)
  }

  func hideDelay(for style: HUDStyle) -> Duration { hideDelayOverride ?? .milliseconds(1100) }

  func show(sliderFraction: Double, mute: Bool, deviceName: String) {
    showCallCount += 1
    showDidUpdatePanel = false
    guard !popupVisibility.isVisible, !fullscreenProvider() else { return }

    let style = settingsManager.appSettings.hudStyle
    let fraction = Float(max(0, min(1, sliderFraction)))
    let content: AnyView
    switch style {
    case .tahoe:
      content = AnyView(
        TahoeStyleHUD(
          sliderFraction: fraction, mute: mute, deviceName: deviceName,
          onSliderChange: { [weak self] in self?.volumeWriter?(Double($0)) },
          onHoverChange: { [weak self] in self?.hoverChanged($0) }
        ))
    case .classic:
      content = AnyView(ClassicStyleHUD(sliderFraction: fraction, mute: mute))
    }
    present(content, style: style, interactive: style == .tahoe)
    let label = deviceName.isEmpty ? "Unknown device" : deviceName
    announce(
      mute ? "\(label), muted" : "\(label), volume \(Int((fraction * 100).rounded())) percent")
  }

  /// Per-app hotkeys are explicit user actions and bypass the fullscreen guard.
  func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) {
    presentApp(title: app.name, icon: app.icon, fraction: sliderFraction, message: nil)
  }

  func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
    presentApp(
      title: app.name, icon: app.icon, fraction: isMuted ? 0 : 1,
      message: isMuted ? "Muted" : "Unmuted")
  }

  func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
    let title =
      [displayName, bundleID].compactMap { $0 }.first { !$0.isEmpty }
      ?? "FineTune isn't controlling this app yet"
    presentApp(title: title, icon: icon, fraction: 0, message: "Not controlled by FineTune")
  }

  private func presentApp(title: String, icon: NSImage?, fraction: Double, message: String?) {
    showCallCount += 1
    showDidUpdatePanel = false
    guard !popupVisibility.isVisible else { return }
    let content = HStack(spacing: 10) {
      if let icon {
        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
      } else {
        Image(systemName: "app.dashed").font(.system(size: 20))
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(TahoeStyleHUD.nameFont).lineLimit(1)
        if let message {
          Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          ProgressView(value: max(0, min(1, fraction)))
          Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%").font(
            .system(size: 11).monospacedDigit())
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(width: 300, height: 72)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    present(AnyView(content), style: .tahoe, interactive: false)
    announce(
      "\(title), \(message ?? "volume \(Int((max(0, min(1, fraction)) * 100).rounded())) percent")")
  }

  private func present(_ content: AnyView, style: HUDStyle, interactive: Bool) {
    let panel = ensurePanel()
    let appearance = settingsManager.appSettings.appearance
    panel.appearance = appearance.nsAppearance
    panel.ignoresMouseEvents = !interactive
    let size = style == .tahoe ? NSSize(width: 300, height: 72) : NSSize(width: 200, height: 200)
    let root = AnyView(content.preferredColorScheme(appearance.swiftUIColorScheme))
    if let host = panel.contentView as? NSHostingView<AnyView> {
      host.rootView = root
    } else {
      panel.contentView = NSHostingView(rootView: root)
    }
    panel.setContentSize(size)
    if let frame = frameProvider() {
      panel.setFrameOrigin(
        Self.computePosition(
          style: style, size: size, visibleFrame: frame,
          suppressionDegraded: mediaKeyStatus.suppressionDegraded
        ))
    }
    panel.orderFrontRegardless()
    showDidUpdatePanel = true
    lastStyle = style
    scheduleHide()
  }

  func hide() {
    hideTask?.cancel()
    hideTask = nil
    panel?.orderOut(nil)
  }

  func shutdown() { hide() }
  func swallowObserved() { swallowedAt = ContinuousClock.now }

  private func soundSettingsChanged() {
    if let swallowedAt, swallowedAt.duration(to: .now) <= .milliseconds(500) {
      mediaKeyStatus.suppressionDegraded = true
    }
  }

  private func scheduleHide() {
    hideTask?.cancel()
    let delay = hideDelay(for: lastStyle)
    let clock = clock
    hideTask = Task { @MainActor [weak self] in
      do { try await clock.sleep(delay) } catch { return }
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  private func hoverChanged(_ hovering: Bool) {
    if hovering {
      hideTask?.cancel()
      hideTask = nil
    } else {
      scheduleHide()
    }
  }

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    self.panel = panel
    return panel
  }

  private func announce(_ message: String) {
    guard let panel else { return }
    NSAccessibility.post(
      element: panel, notification: .announcementRequested,
      userInfo: [
        .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }

  static func computePosition(
    style: HUDStyle, size: NSSize, visibleFrame: NSRect, suppressionDegraded: Bool
  ) -> NSPoint {
    if style == .classic {
      return NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + 140)
    }
    let x =
      suppressionDegraded
      ? visibleFrame.minX + visibleFrame.width / 4 - size.width / 2
      : visibleFrame.maxX - size.width - 8
    return NSPoint(x: x, y: visibleFrame.maxY - size.height - 8)
  }

  private static func foregroundIsFullscreen() -> Bool {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let frame = NSScreen.main?.frame,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    return windows.contains { info in
      guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return false }
      return rect.width >= frame.width && rect.height >= frame.height
    }
  }
}
