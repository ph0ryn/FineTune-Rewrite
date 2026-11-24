// Offscreen AppKit control-bridging tests for DeviceRow, Settings, and Inspector switches.
// Uses only public AppKit controls (NSTextField, NSSegmentedControl, NSSwitch); no Vision OCR,
// no ScreenCaptureKit, no private SwiftUI view proxies, and no synthetic pointer coordinates.
import AppKit
import FineTuneDomain
import FineTunePlatform
import Observation
import SwiftUI
import Testing

@testable import FineTune

@Suite("Device and settings AppKit control bridging")
@MainActor
struct DeviceSettingsParityTests {
  @Test(
    "Unknown and read-only device volume never create an editable percentage field",
    arguments: [false, true])
  func unavailableDevicePercentageIsNotEditable(readOnly: Bool) throws {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].volume = readOnly ? 0.4 : nil
    source.snapshot.outputDevices[0].canSetVolume = !readOnly
    let fixture = try OffscreenHostFixture(
      source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output), width: 560)
    #expect(
      !leafDescendants(of: fixture.host).contains {
        ($0 as? NSTextField)?.isEditable == true
      })
    #expect(source.events.isEmpty)
  }

  @Test("The General tab mounts its Theme segmented control and preference switches inside bounds")
  func generalTabNativeControls() throws {
    let snapshot = SettingsSnapshot(
      settings: AppSettings(), isAccessibilityTrusted: false, isMediaKeyOffline: false,
      error: nil, device: testDeviceSettings())
    var events: [String] = []
    let actions = SettingsActions(
      updateSettings: { _ in events.append("settings") },
      recordShortcut: { _, _ in events.append("shortcut") },
      requestAccessibility: { events.append("accessibility") },
      retryMediaKeys: { events.append("retry") }, resetAll: { events.append("reset") },
      device: recordingDeviceSettingsActions { events.append($0) })
    let view = FineTuneSettingsView(
      read: { snapshot }, actions: actions, updates: .unavailable(reason: "No test feed."))
    let fixture = try OffscreenHostFixture(view, width: 720, height: 560)
    #expect(abs(fixture.host.fittingSize.width - 720) <= 0.5)
    #expect(abs(fixture.host.fittingSize.height - 560) <= 0.5)
    let segmented = leafDescendants(of: fixture.host).compactMap { $0 as? NSSegmentedControl }
      .filter { $0.segmentCount == AppearancePreference.allCases.count }
    let theme = try #require(segmented.first, "The Theme segmented picker must render")
    #expect(segmented.count == 1)
    #expect(
      (0..<theme.segmentCount).compactMap { theme.label(forSegment: $0) }
        == AppearancePreference.allCases.map(\.description))
    let switches = leafDescendants(of: fixture.host).compactMap { $0 as? NSSwitch }
    #expect(switches.count == 2, "Launch at Login and Device Disconnect Alerts both render")
    for control in [theme as NSView] + switches.map({ $0 as NSView }) {
      let frame = fixture.host.convert(control.bounds, from: control)
      #expect(frame.width > 0 && frame.height > 0)
      #expect(
        fixture.host.bounds.contains(frame),
        "\(type(of: control)) rendered at \(frame), outside \(fixture.host.bounds)")
    }
    #expect(switches.allSatisfy { $0.isEnabled })
    #expect(events.isEmpty)
  }

  @Test(
    "The inspector override switch bridges native clicks to software override state",
    arguments: [VolumeControlTier.hardware, .ddc])
  func inspectorOverrideSwitchBridging(tier: VolumeControlTier) throws {
    let observed = ObservedVolumeOverride()
    let harness = SoftwareVolumeControlsHarness(autoDetectedTier: tier, observed: observed)
    let fixture = try OffscreenHostFixture(
      VStack(alignment: .leading) { harness }.padding(), width: 520, height: 140)
    let toggle = try singleSwitch(
      in: fixture.host, "The override row renders exactly one switch")
    #expect(toggle.isEnabled)
    let frame = fixture.host.convert(toggle.bounds, from: toggle)
    #expect(frame.width > 0 && frame.height > 0)
    #expect(fixture.host.bounds.contains(frame))
    #expect(toggle.state == .off)
    #expect(observed.overrides.isEmpty)

    toggle.performClick(nil)
    fixture.render()
    let enabled = try singleSwitch(
      in: fixture.host, "The override row renders exactly one switch after the first click")
    #expect(enabled.state == .on)
    #expect(observed.currentOverride == .software)
    #expect(observed.overrides == [.software])

    enabled.performClick(nil)
    fixture.render()
    let disabled = try singleSwitch(
      in: fixture.host, "The override row renders exactly one switch after the second click")
    #expect(disabled.state == .off)
    #expect(observed.currentOverride == nil)
    #expect(observed.overrides == [.software, nil])
  }

  @Test("Settings tabs render as in-bounds plain buttons without a clipped TabView")
  func settingsTabsRenderInsideBounds() throws {
    let snapshot = SettingsSnapshot(
      settings: AppSettings(), isAccessibilityTrusted: false, isMediaKeyOffline: false,
      error: nil, device: testDeviceSettings())
    let actions = SettingsActions(
      updateSettings: { _ in }, recordShortcut: { _, _ in }, requestAccessibility: {},
      retryMediaKeys: {}, resetAll: {}, device: recordingDeviceSettingsActions { _ in })
    let view = FineTuneSettingsView(
      read: { snapshot }, actions: actions, updates: .unavailable(reason: "No test feed."))
    let fixture = try OffscreenHostFixture(view, width: 720, height: 560)
    let tabs = settingsTabButtons(in: fixture.host)
    #expect(tabs.map(\.title) == ["General", "Audio", "Shortcuts", "Updates", "About"])
    #expect(!leafDescendants(of: fixture.host).contains { $0 is NSTabView })
    #expect(tabs.allSatisfy { !$0.isBordered && $0.image == nil })
    for tab in tabs {
      let frame = fixture.host.convert(tab.bounds, from: tab)
      #expect(frame.width > 0 && frame.height > 0)
      #expect(fixture.host.bounds.contains(frame), "\(tab.title) rendered at \(frame)")
      let topDistance = min(frame.minY, fixture.host.bounds.maxY - frame.maxY)
      #expect(topDistance < 60, "\(tab.title) must stay in the top tab row")
    }
  }

  @Test("Settings tabs switch content and mount shortcut recorders only while selected")
  func settingsTabsSwitchAndRemainLazy() throws {
    let snapshot = SettingsSnapshot(
      settings: AppSettings(), isAccessibilityTrusted: false, isMediaKeyOffline: false,
      error: nil, device: testDeviceSettings())
    let actions = SettingsActions(
      updateSettings: { _ in }, recordShortcut: { _, _ in }, requestAccessibility: {},
      retryMediaKeys: {}, resetAll: {}, device: recordingDeviceSettingsActions { _ in })
    let view = FineTuneSettingsView(
      read: { snapshot }, actions: actions, updates: .unavailable(reason: "No test feed."))
    let fixture = try OffscreenHostFixture(view, width: 720, height: 560)
    let tabs = settingsTabButtons(in: fixture.host)
    let audio = try #require(tabs.first { $0.title == "Audio" })
    let shortcuts = try #require(tabs.first { $0.title == "Shortcuts" })
    let general = try #require(tabs.first { $0.title == "General" })

    audio.performClick(nil)
    fixture.render()
    #expect(
      !leafDescendants(of: fixture.host).compactMap { $0 as? NSTextField }
        .filter(\.isEditable).isEmpty)
    #expect(leafDescendants(of: fixture.host).compactMap { $0 as? NSSearchField }.isEmpty)

    shortcuts.performClick(nil)
    fixture.render()
    #expect(leafDescendants(of: fixture.host).compactMap { $0 as? NSSearchField }.count == 4)

    general.performClick(nil)
    fixture.render()
    #expect(leafDescendants(of: fixture.host).compactMap { $0 as? NSSearchField }.isEmpty)
    #expect(
      leafDescendants(of: fixture.host).compactMap { $0 as? NSTextField }
        .filter(\.isEditable).isEmpty)
  }

  @Test("Updates switch disables when unavailable and bridges live clicks when available")
  func updatesSwitchBridging() throws {
    let unavailableView = SettingsUpdatesView(
      capability: .unavailable(reason: "No signed rewrite release feed is configured."),
      version: "8.1")
    let unavailableFixture = try OffscreenHostFixture(unavailableView, width: 640, height: 380)
    let disabledSwitch = try singleSwitch(
      in: unavailableFixture.host, "Unavailable updates still render one disabled switch")
    #expect(!disabledSwitch.isEnabled)

    var snapshot = SettingsUpdatePresentation(
      automaticallyChecks: true, lastChecked: .now.addingTimeInterval(-60),
      isChecking: false, error: nil)
    var requests: [String] = []
    let capability = SettingsUpdateCapability.available(
      read: { snapshot },
      actions: SettingsUpdateActions(
        checkNow: { requests.append("check") },
        setAutomaticChecks: {
          snapshot.automaticallyChecks = $0
          requests.append("automatic:\($0)")
        }))
    let availableView = SettingsUpdatesView(capability: capability, version: "8.1")
    let fixture = try OffscreenHostFixture(availableView, width: 640, height: 380)
    let automaticChecks = try singleSwitch(
      in: fixture.host, "Available updates render one enabled Automatic updates switch")
    #expect(automaticChecks.isEnabled)
    #expect(automaticChecks.state == .on)

    automaticChecks.performClick(nil)
    fixture.render()
    let unchecked = try singleSwitch(
      in: fixture.host, "The Automatic updates switch still renders after the first click")
    #expect(unchecked.state == .off)
    #expect(!snapshot.automaticallyChecks)
    #expect(requests == ["automatic:false"])

    unchecked.performClick(nil)
    fixture.render()
    let rechecked = try singleSwitch(
      in: fixture.host, "The Automatic updates switch still renders after the second click")
    #expect(rechecked.state == .on)
    #expect(snapshot.automaticallyChecks)
    #expect(requests == ["automatic:false", "automatic:true"])
  }
}

@MainActor
@Observable
private final class ObservedVolumeOverride {
  var currentOverride: VolumeControlTier?
  var overrides: [VolumeControlTier?] = []

  func apply(_ value: VolumeControlTier?) {
    currentOverride = value
    overrides.append(value)
  }
}

/// Renders only the production override section, so the sheet's HAL-observing `.onAppear` never runs.
@MainActor
private struct SoftwareVolumeControlsHarness: View {
  let autoDetectedTier: VolumeControlTier
  let observed: ObservedVolumeOverride

  var body: some View {
    DeviceDetailSheet(
      device: AudioDevice(
        id: 901, uid: "leaf-inspector", name: "Leaf device", icon: nil,
        supportsAutoEQ: false),
      transportType: .usb, autoDetectedTier: autoDetectedTier,
      currentOverride: observed.currentOverride,
      onOverrideChange: { observed.apply($0) }, onDismiss: {}
    )
    .softwareVolumeControls
  }
}

@MainActor
private final class OffscreenHostFixture<Content: View> {
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(
    _ content: Content, width: CGFloat, height: CGFloat? = nil,
    colorScheme: ColorScheme = .light
  ) throws {
    _ = NSApplication.shared
    let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    host = NSHostingView(
      rootView: AnyView(
        content.environment(\.colorScheme, colorScheme)
          .background(Color(nsColor: .windowBackgroundColor))))
    host.appearance = appearance
    host.setFrameSize(NSSize(width: width, height: height ?? host.fittingSize.height))
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: host.frame.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    render()
    // Trigger one offscreen display pass so SwiftUI creates native AppKit control bridges.
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
  }

  isolated deinit { window.close() }

  func render() {
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
  }
}

@MainActor
private func settingsTabButtons(in host: NSView) -> [NSButton] {
  let titles = ["General", "Audio", "Shortcuts", "Updates", "About"]
  return leafDescendants(of: host).compactMap { $0 as? NSButton }
    .filter { titles.contains($0.title) }
}

@MainActor
private func singleSwitch(in host: NSView, _ comment: Comment) throws -> NSSwitch {
  let switches = leafDescendants(of: host).compactMap { $0 as? NSSwitch }
  #expect(switches.count == 1, comment)
  return try #require(switches.first)
}
