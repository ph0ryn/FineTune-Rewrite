// Independent production-leaf UI regressions. Offscreen AppKit hosts use fake actions only.
// No production Root, audio runtime, device reader, global settings, or browser is started.
// Visible fields use native-view/bitmap checks; commits use the existing binding/capability boundary.
// An unshown window's key events or unevaluated ButtonStyle are not acceptance oracles.
import AppKit
import FineTuneDomain
import FineTunePlatform
import SwiftUI
import Testing
import Vision

@testable import FineTune

@Suite("Device and settings original UI parity")
@MainActor
struct DeviceSettingsParityTests {
  @Test(
    "The actual device row exposes the shared percentage editor and its scoped commit binding",
    arguments: [false, true])
  func devicePercentageCommitUsesExistingAction(isInput: Bool) throws {
    let source = MixerTestSource()
    let scope: MixerDeviceScope = isInput ? .input : .output
    let device = isInput ? source.snapshot.inputDevices[0] : source.snapshot.outputDevices[0]
    let row = source.bindings.deviceRow(device, scope: scope)
    let fixture = try LeafUIFixture(row, width: 560)
    let field = try #require(
      leafDescendants(of: fixture.host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    let slider = try #require(row.slider)
    let format = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
    #expect(field.stringValue == format.format(slider.wrappedValue))
    #expect(source.events.isEmpty)

    // Exercise the shared editor's parse/commit boundary, not an unshown window's event loop.
    let percentage = VolumePercentageField(
      value: slider, range: 0...100, label: "\(device.device.name) volume percentage")
    percentage.boundedValue.wrappedValue = try format.parseStrategy.parse("60%")
    #expect(source.events == ["device-volume"])
    #expect(source.lastDeviceScope == scope && source.lastDeviceUID == device.id)
    let gain = try #require(source.lastGain)
    #expect(abs(gain - (isInput ? 0.6 : 0.36)) < 0.000_001)
    percentage.boundedValue.wrappedValue = 1.4
    #expect(source.lastGain == 1)
    percentage.boundedValue.wrappedValue = -0.2
    #expect(source.lastGain == 0)
  }

  @Test(
    "Unknown and read-only device volume never create an editable percentage",
    arguments: [false, true])
  func unavailableDevicePercentageIsNotEditable(readOnly: Bool) throws {
    let source = MixerTestSource()
    source.snapshot.outputDevices[0].volume = readOnly ? 0.4 : nil
    source.snapshot.outputDevices[0].canSetVolume = !readOnly
    let fixture = try LeafUIFixture(
      source.bindings.deviceRow(source.snapshot.outputDevices[0], scope: .output), width: 560)
    #expect(
      !leafDescendants(of: fixture.host).contains {
        ($0 as? NSTextField)?.isEditable == true
      })
    #expect(source.events.isEmpty)
  }

  @Test("The actual General tab keeps the original preference descriptions visible")
  func generalDescriptionsAreNotHoverOnly() throws {
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
    let fixture = try LeafUIFixture(
      FineTuneSettingsView(
        read: { snapshot }, actions: actions, updates: .unavailable(reason: "No test feed.")),
      width: 720, height: 560)
    let text = try fixture.visibleText(artifactName: "general")
    #expect(text.contains("Theme"), "Positive control: the actual General tab must render.")
    #expect(text.contains("Start FineTune when you log in"))
    #expect(text.contains("Show notification when an audio device disconnects"))
    #expect(events.isEmpty)
  }

  @Test(
    "The actual inspector override row shows its observed automatic tier without HAL reads",
    arguments: [VolumeControlTier.hardware, .ddc])
  func inspectorAutomaticBadge(tier: VolumeControlTier) throws {
    var overrides: [VolumeControlTier?] = []
    let sheet = DeviceDetailSheet(
      device: AudioDevice(
        id: 901, uid: "leaf-inspector", name: "Leaf device", icon: nil,
        supportsAutoEQ: false),
      transportType: .usb, autoDetectedTier: tier, currentOverride: nil,
      onOverrideChange: { overrides.append($0) }, onDismiss: {})
    let fixture = try LeafUIFixture(
      VStack(alignment: .leading) { sheet.softwareVolumeControls }.padding(),
      width: 520, height: 140)
    let text = try fixture.visibleText(
      artifactName: tier == .hardware ? "inspector-hardware" : "inspector-ddc")
    #expect(text.contains(tier == .hardware ? "Auto: Hardware" : "Auto: DDC"))
    #expect(text.contains("Use FineTune's software volume"))
    #expect(overrides.isEmpty)
    sheet.useSoftwareBinding.wrappedValue = true
    sheet.useSoftwareBinding.wrappedValue = false
    #expect(overrides == [.software, nil])
  }

  @Test("About shows the actual icon input, short version, build, original links and copyright")
  func aboutOriginalContents() throws {
    _ = NSApplication.shared
    let icon = try #require(NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
    var openedURLs: [URL] = []
    let fixture = try LeafUIFixture(
      SettingsAboutView(
        metadata: SettingsAboutPresentation(version: "1.2.3", build: "19", year: 2026),
        appIcon: icon
      )
      .environment(
        \.openURL,
        OpenURLAction {
          openedURLs.append($0)
          return .handled
        }),
      width: 640, height: 430)
    let text = try fixture.visibleText(artifactName: "about")
    #expect(text.contains("FineTune"))
    #expect(text.contains("Version 1.2.3 (19)"))
    #expect(text.contains("Star on GitHub"))
    #expect(text.contains("GPL-3.0"))
    #expect(text.contains("2026 Ronit Singh"))
    #expect(text.contains("Independent rewrite"))
    #expect(openedURLs.isEmpty)
  }

  @Test("Missing About metadata is explicit rather than a fabricated release version")
  func aboutMissingMetadata() throws {
    let metadata = SettingsAboutPresentation(version: nil, build: nil, year: 2028)
    let fixture = try LeafUIFixture(
      SettingsAboutView(metadata: metadata, appIcon: nil), width: 640, height: 430)
    let text = try fixture.visibleText(artifactName: "about-unavailable")
    #expect(text.contains("Version unavailable (build unavailable)"))
    #expect(text.contains("App icon unavailable"))
    #expect(metadata.copyright == "© 2026–2028 Ronit Singh")
  }

  @Test(
    "An unconfigured updater keeps every original field visible and unavailable without fake actions"
  )
  func unavailableUpdatesKeepOriginalFields() throws {
    let reason = "No signed rewrite release feed is configured."
    let view = SettingsUpdatesView(capability: .unavailable(reason: reason))
    let fixture = try LeafUIFixture(view, width: 640, height: 380)
    let text = try fixture.visibleText(artifactName: "updates-unconfigured")
    #expect(text.contains(reason), "Positive control: the real unavailable reason must render.")
    #expect(text.contains("Automatic updates"))
    #expect(text.contains("Last checked"))
    #expect(text.contains("Never checked"))
    #expect(text.contains("Version"))
    #expect(text.contains("Not configured"))
    #expect(text.contains("Check Now"))
    #expect(!view.canCheckNow)
  }

  @Test("An available updater shows its real check date and disables checks while busy")
  func availableUpdatesUseObservedState() throws {
    var snapshot = SettingsUpdatePresentation(
      automaticallyChecks: true, lastChecked: .now.addingTimeInterval(-60),
      isChecking: false, error: nil)
    var requests: [String] = []
    let capability = SettingsUpdateCapability.available(
      read: { snapshot },
      actions: SettingsUpdateActions(
        checkNow: { requests.append("check") },
        setAutomaticChecks: { requests.append("automatic:\($0)") }))
    let view = SettingsUpdatesView(capability: capability, version: "8.1")
    let fixture = try LeafUIFixture(view, width: 640, height: 380)
    let text = try fixture.visibleText(artifactName: "updates-available")
    #expect(text.contains("Version 8.1"))
    #expect(text.contains("Last checked") && text.contains("Check Now"))
    #expect(!text.contains("Never checked") && !text.contains("Not configured"))
    #expect(view.canCheckNow)
    snapshot.isChecking = true
    #expect(!view.canCheckNow)
    #expect(requests.isEmpty)
  }
}

@MainActor
private final class LeafUIFixture<Content: View> {
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(_ content: Content, width: CGFloat, height: CGFloat? = nil) throws {
    _ = NSApplication.shared
    host = NSHostingView(
      rootView: AnyView(content.environment(\.colorScheme, .light).background(Color.white)))
    host.appearance = NSAppearance(named: .aqua)
    host.setFrameSize(NSSize(width: width, height: height ?? host.fittingSize.height))
    window = NSWindow(
      contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: host.frame.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // Render the offscreen component and its native fields without ordering the window in.
    _ = try renderBitmap()
  }

  private func renderBitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  func visibleText(artifactName: String? = nil) throws -> String {
    let bitmap = try renderBitmap()
    if let artifactName,
      let path = ProcessInfo.processInfo.environment["FINETUNE_LEAF_UI_ARTIFACT_DIRECTORY"]
    {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: directory.appendingPathComponent("\(artifactName).png"))
    }
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let strings = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    #expect(!strings.isEmpty, "The actual offscreen component must produce recognizable text.")
    return strings.joined(separator: " ").replacingOccurrences(of: "’", with: "'")
  }
}

@MainActor
private func leafDescendants(of view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + leafDescendants(of: $0) }
}
