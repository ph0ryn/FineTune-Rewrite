// Independent production-leaf UI regressions. Offscreen AppKit hosts use fake actions only.
// No production Root, audio runtime, device reader, global settings, or browser is started.
// The offscreen SwiftUI host exposes no NSAccessibility text tree; OCR on its actual bitmap checks
// rendered copy visibility. Semantic projection values remain a separate copy oracle; control
// frames and actions come from the rendered host. Diagnostic PNGs are opt-in only.
import AppKit
import FineTuneDomain
import FineTunePlatform
import Observation
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
    let copy = SettingsGeneralCopy()
    // The exact preference strings are asserted in AppPresentationContractTests; this rendered tab
    // still asserts the same copy value through the production view and its visible glyphs.
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
    #expect(view.generalCopy == copy)
    // The production view declares the original 720x560 settings frame. Host it at that declared
    // viewport: with a larger fixture host, reading fittingSize made NSHostingView adopt 720x560
    // while the platform switches still carried frames from the larger layout pass, so their
    // converted frames fell outside host.bounds. Use the declared size and flush layout first.
    let fixture = try LeafUIFixture(view, width: 720)
    fixture.show()
    try fixture.writeArtifact("general")
    #expect(abs(fixture.host.fittingSize.width - 720) <= 0.5)
    #expect(abs(fixture.host.fittingSize.height - 560) <= 0.5)
    fixture.render()
    let text = try fixture.visibleText(artifactName: "general")
    #expect(text.contains("Theme"), "Positive control: the actual General tab must render.")
    #expect(text.contains("Start FineTune when you log in"))
    #expect(text.contains("Show notification when an audio device disconnects"))
    let segmented = leafDescendants(of: fixture.host).compactMap { $0 as? NSSegmentedControl }
      .filter { $0.segmentCount == AppearancePreference.allCases.count }
    let theme = try #require(segmented.first, "The actual Theme segmented picker must render")
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
    "The actual inspector override row shows its observed automatic tier without HAL reads",
    arguments: [VolumeControlTier.hardware, .ddc])
  func inspectorAutomaticBadge(tier: VolumeControlTier) throws {
    let observed = ObservedVolumeOverride()
    let harness = SoftwareVolumeControlsHarness(autoDetectedTier: tier, observed: observed)
    let fixture = try LeafUIFixture(
      VStack(alignment: .leading) { harness }.padding(), width: 520, height: 140)
    let text = try fixture.visibleText(
      artifactName: tier == .hardware ? "inspector-hardware" : "inspector-ddc")
    #expect(text.contains(tier == .hardware ? "Auto: Hardware" : "Auto: DDC"))
    #expect(text.contains("Use FineTune's software volume"))
    // The exact badge/accessibility copy is asserted in AppPresentationContractTests; the rendered
    // section below is selected by the same production predicate that selects the toggle.
    #expect(
      DeviceDetailSheet.shouldShowToggle(
        autoTier: tier, isInput: false, allowsVolumeOverride: true, hasOverrideAction: true))
    // The platform switch reports a click's new state only after SwiftUI's observation-driven
    // render. Query the live descendant after every render instead of holding a pre-click view.
    fixture.show()
    let toggle = try singleSwitch(
      in: fixture.host, "The override row renders exactly one switch")
    #expect(toggle.isEnabled)
    let frame = fixture.host.convert(toggle.bounds, from: toggle)
    #expect(frame.width > 0 && frame.height > 0)
    #expect(fixture.host.bounds.contains(frame))
    #expect(toggle.state == .off)
    #expect(observed.overrides.isEmpty)

    // Drive the actual rendered NSSwitch action instead of assigning the production binding.
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

  @Test("About shows the actual icon input, short version, build, original links and copyright")
  func aboutOriginalContents() throws {
    _ = NSApplication.shared
    let icon = try #require(NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
    var openedURLs: [URL] = []
    let copy = SettingsAboutCopy()
    // The exact copy struct and destinations live in AppPresentationContractTests; the rendered
    // links below keep the action targets and visible labels.
    let metadata = SettingsAboutPresentation(version: "1.2.3", build: "19", year: 2026)
    let view = SettingsAboutView(metadata: metadata, appIcon: icon)
    #expect(view.copy == copy)
    #expect(view.metadata.versionDescription == "Version 1.2.3 (19)")
    #expect(view.metadata.copyright == "© 2026 Ronit Singh")
    let fixture = try LeafUIFixture(
      view.environment(
        \.openURL,
        OpenURLAction {
          openedURLs.append($0)
          return .handled
        }),
      width: 640, height: 430)
    #expect(icon.size.width > 0)
    fixture.show()
    let text = try fixture.visibleText(artifactName: "about")
    #expect(text.contains("FineTune"))
    #expect(text.contains("Version 1.2.3 (19)"))
    #expect(text.contains("Star on GitHub"))
    #expect(text.contains("GPL-3.0"))
    #expect(text.contains("2026 Ronit Singh"))
    #expect(text.contains("Independent rewrite"))
    #expect(!text.localizedCaseInsensitiveContains("icon unavailable"))

    // The two original links are the actual rendered native link proxies; click each one and
    // observe the injected OpenURLAction.
    let links = leafDescendants(of: fixture.host).compactMap { $0 as? NSButton }
    #expect(links.count == 2)
    let frames = links.map { fixture.host.convert($0.bounds, from: $0) }.sorted {
      fixture.host.isFlipped ? $0.minY < $1.minY : $0.minY > $1.minY
    }
    for frame in frames {
      #expect(frame.width > 0 && frame.height > 0)
      #expect(fixture.host.bounds.contains(frame))
    }
    #expect(openedURLs.isEmpty)
    for frame in frames {
      try fixture.click(CGPoint(x: frame.midX, y: frame.midY))
    }
    #expect(openedURLs == [copy.starURL, copy.licenseURL])
  }

  @Test("Missing About metadata is explicit rather than a fabricated release version")
  func aboutMissingMetadata() throws {
    let metadata = SettingsAboutPresentation(version: nil, build: nil, year: 2028)
    let view = SettingsAboutView(metadata: metadata, appIcon: nil)
    #expect(view.appIcon == nil)
    #expect(view.copy.appIconUnavailable == "App icon unavailable")
    let fixture = try LeafUIFixture(view, width: 640, height: 430)
    let text = try fixture.visibleText(
      artifactName: "about-unavailable", requiringVisible: "icon unavailable")
    #expect(text.contains("Version unavailable (build unavailable)"))
    // The footer links still render in the explicit-missing-metadata state.
    let links = leafDescendants(of: fixture.host).compactMap { $0 as? NSButton }
    #expect(links.count == 2)
    for link in links {
      let frame = fixture.host.convert(link.bounds, from: link)
      #expect(frame.width > 0 && frame.height > 0)
      #expect(fixture.host.bounds.contains(frame))
    }
  }

  @Test(
    "An unconfigured updater keeps every original field visible and unavailable without fake actions"
  )
  func unavailableUpdatesKeepOriginalFields() throws {
    let reason = "No signed rewrite release feed is configured."
    let copy = SettingsUpdatesCopy()
    // The exact section/state copy is asserted in AppPresentationContractTests; this rendered tab
    // keeps the live capability, version, reason and visible glyphs.
    let view = SettingsUpdatesView(capability: .unavailable(reason: reason), version: "8.1")
    #expect(view.copy == copy)
    #expect(view.version == "8.1")
    guard case .unavailable(let renderedReason) = view.capability else {
      Issue.record("Expected the unavailable updater capability")
      return
    }
    #expect(renderedReason == reason, "The reason the actual view renders")
    #expect(!view.canCheckNow)
    let fixture = try LeafUIFixture(view, width: 640, height: 380)
    fixture.show()
    let text = try fixture.visibleText(artifactName: "updates-unconfigured")
    #expect(text.contains(reason))
    #expect(text.contains("Automatic updates"))
    #expect(text.contains("Last checked"))
    #expect(text.contains("Never checked"))
    #expect(text.contains("Version"))
    #expect(text.contains("Not configured"))
    #expect(text.contains("Check Now"))
    let switches = leafDescendants(of: fixture.host).compactMap { $0 as? NSSwitch }
    #expect(switches.count == 1)
    #expect(!(try #require(switches.first)).isEnabled)
    // The Check Now control is rendered but disabled because no capability exists. `Form` also
    // emits full-row focus rings, so select the compact control below the rendered switch row.
    let frame = try checkNowButtonFrame(in: fixture.host)
    #expect(frame.width > 0 && frame.height > 0)
    #expect(fixture.host.bounds.contains(frame))
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
        setAutomaticChecks: {
          snapshot.automaticallyChecks = $0
          requests.append("automatic:\($0)")
        }))
    let view = SettingsUpdatesView(capability: capability, version: "8.1")
    #expect(view.copy.checkNow == "Check Now")
    #expect(view.version == "8.1")
    #expect(view.copy.versionLinePrefix(version: view.version) == "Version 8.1 ·")
    #expect(view.canCheckNow)
    let fixture = try LeafUIFixture(view, width: 640, height: 380)
    fixture.show()
    let text = try fixture.visibleText(artifactName: "updates-available")
    #expect(text.contains("Version 8.1"))
    #expect(text.contains("Last checked"))
    #expect(text.contains("Check Now"))
    #expect(!text.contains("Never checked"))
    #expect(!text.contains("Not configured"))
    let frame = try checkNowButtonFrame(in: fixture.host)
    #expect(fixture.host.bounds.contains(frame))
    try fixture.click(CGPoint(x: frame.midX, y: frame.midY))
    #expect(requests == ["check"])

    // The actual rendered Automatic updates NSSwitch reports its real observed state, and its
    // native action writes the new value back through the production binding. The platform switch
    // publishes that rendered state only after the observation-driven render, so re-query it.
    let automaticChecks = try singleSwitch(
      in: fixture.host, "The available Automatic updates switch renders once")
    #expect(automaticChecks.isEnabled)
    #expect(automaticChecks.state == .on)
    automaticChecks.performClick(nil)
    fixture.render()
    let unchecked = try singleSwitch(
      in: fixture.host, "The Automatic updates switch still renders after the first click")
    #expect(unchecked.state == .off)
    #expect(!snapshot.automaticallyChecks)
    #expect(requests == ["check", "automatic:false"])
    unchecked.performClick(nil)
    fixture.render()
    let rechecked = try singleSwitch(
      in: fixture.host, "The Automatic updates switch still renders after the second click")
    #expect(rechecked.state == .on)
    #expect(snapshot.automaticallyChecks)
    #expect(requests == ["check", "automatic:false", "automatic:true"])

    // The capability reads the live observation instead of a captured initial value, and the
    // actual rendered button is disabled while busy.
    snapshot.isChecking = true
    #expect(!view.canCheckNow)
    let busy = try LeafUIFixture(view, width: 640, height: 380)
    busy.show()
    let busyFrame = try checkNowButtonFrame(in: busy.host)
    #expect(busy.host.bounds.contains(busyFrame))
    try busy.click(CGPoint(x: busyFrame.midX, y: busyFrame.midY))
    #expect(requests == ["check", "automatic:false", "automatic:true"])
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
    // Force the offscreen display pass so native field bridges exist before the assertion.
    _ = try renderBitmap()
  }

  private func renderBitmap() throws -> NSBitmapImageRep {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }

  func visibleText(artifactName: String, requiringVisible phrase: String? = nil) throws -> String {
    let bitmap = try renderBitmap()
    try writeArtifact(artifactName)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let observations = request.results ?? []
    let strings = observations.compactMap { $0.topCandidates(1).first?.string }
    #expect(!strings.isEmpty, "The actual rendered component must produce recognizable text.")
    if let phrase {
      let match = try #require(
        observations.first { observation in
          observation.topCandidates(1).first?.string.localizedCaseInsensitiveContains(phrase)
            == true
        },
        "Expected rendered text ‘\(phrase)’ in \(strings)")
      #expect(match.boundingBox.width > 0 && match.boundingBox.height > 0)
      #expect(
        CGRect(x: 0, y: 0, width: 1, height: 1).contains(match.boundingBox),
        "Rendered text ‘\(phrase)’ must remain inside the captured component")
    }
    return strings.joined(separator: " ").replacingOccurrences(of: "’", with: "'")
  }

  func render() {
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
  }

  func show() {
    window.orderFrontRegardless()
    _ = window.makeFirstResponder(host)
    render()
  }

  func click(_ point: CGPoint) throws {
    let location = host.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
    render()
  }

  /// Opt-in diagnostic evidence only; never part of the pass/fail result.
  func writeArtifact(_ name: String) throws {
    guard
      let path = ProcessInfo.processInfo.environment["FINETUNE_LEAF_UI_ARTIFACT_DIRECTORY"]
    else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent("\(name).png"))
  }
}

/// The single native switch rendered by the production leaf. SwiftUI publishes a click's new
/// switch state only after the observation-driven render, so callers query this after `render()`.
@MainActor
private func singleSwitch(in host: NSView, _ comment: Comment) throws -> NSSwitch {
  let switches = leafDescendants(of: host).compactMap { $0 as? NSSwitch }
  #expect(switches.count == 1, comment)
  return try #require(switches.first)
}

/// The Check Now button is the compact trailing control in the row below the Automatic updates
/// switch. A grouped `Form` also emits a full-row focus ring for each row, so the first proxy is
/// not necessarily the button; the rendered switch row identifies the actual button frame.
@MainActor
private func checkNowButtonFrame(in host: NSView) throws -> CGRect {
  let switchFrame = try #require(
    leafDescendants(of: host).compactMap { $0 as? NSSwitch }
      .map { host.convert($0.bounds, from: $0) }
      .first)
  let candidates = nativeButtonProxyFrames(in: host, minimumWidth: 60).filter { frame in
    let isBelowSwitch =
      host.isFlipped ? frame.midY > switchFrame.maxY : frame.midY < switchFrame.minY
    return isBelowSwitch && frame.width <= 240 && frame.height <= 30
  }
  #expect(candidates.count == 1, "The Check Now button renders once below the switch row")
  return try #require(candidates.first)
}
