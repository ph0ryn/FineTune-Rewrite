// No-render presentation contracts for the mixer surface. These assert the exact production copy
// and static presentation mappings the rendered suites also read. No application, window, view,
// bitmap, event or Vision request is constructed, and no loop or sleep runs. The convention is
// enforced by review, not by the compiler: the FineTune module still links SwiftUI/AppKit.
import FineTuneDomain
import Testing

@testable import FineTune

@Suite("Presentation contract: mixer copy and static presentation")
struct MixerContractTests {
  @Test("The route menu renders exactly these mode and option strings")
  func routeMenuCopy() {
    let copy = MixerAppRouteCopy()
    #expect(copy.singleMode == "Single")
    #expect(copy.multiMode == "Multi")
    #expect(copy.modeLabel(.single) == "Single")
    #expect(copy.modeLabel(.multi) == "Multi")
    #expect(copy.systemAudio == "System Audio")
    #expect(copy.followsDefault == "Follows macOS default")
    #expect(copy.unavailableInMulti == "Not available in multi mode")
    #expect(copy.systemAudioDetail(isMulti: false) == "Follows macOS default")
    #expect(copy.systemAudioDetail(isMulti: true) == "Not available in multi mode")
  }

  @Test("The icon header has no raw Edit or Devices text")
  func headerCopyAndStringPurity() {
    let copy = MixerHeaderCopy()
    #expect(copy.reorder == "Reorder devices")
    #expect(copy.doneReordering == "Done reordering")
    #expect(copy.dragHint == "Drag to set priority")
    #expect(copy.retryAudio == "Retry Audio")
    #expect(copy.settings == "Settings")
    #expect(copy.outputTab == "Output Devices")
    #expect(copy.inputTab == "Input Devices")
    #expect(!copy.allStrings.contains("Edit"), "The header has no raw Edit text")
    #expect(!copy.allStrings.contains("Devices"), "The header has no raw Devices picker label")
  }

  @Test("The footer quit control keeps its exact label, shortcut and accessibility text")
  func footerCopy() {
    let copy = MixerFooterCopy()
    #expect(copy.quit == "Quit")
    #expect(copy.shortcut == "⌘Q")
    #expect(copy.accessibilityLabel == "Quit FineTune-Rewrite")
  }

  @Test("Device badge selection resolves to the documented fill and glyph")
  func deviceBadgeStyle() {
    #expect(
      DeviceBadgeStyle.resolve(isSelected: true)
        == DeviceBadgeStyle(fill: .accentGradient, glyph: .white))
    #expect(
      DeviceBadgeStyle.resolve(isSelected: false)
        == DeviceBadgeStyle(fill: .mono, glyph: .mono))
  }

  @MainActor
  @Test(
    "The inspector automatic tier renders its exact badge and accessibility copy",
    arguments: [VolumeControlTier.hardware, .ddc])
  func inspectorAutomaticTierCopy(tier: VolumeControlTier) {
    let expected =
      tier == .hardware
      ? (badge: "Auto: Hardware", accessibility: "Auto-detected volume control: Hardware")
      : (badge: "Auto: DDC", accessibility: "Auto-detected volume control: DDC")
    #expect(DeviceDetailSheet.automaticTierBadge(tier) == expected.badge)
    #expect(DeviceDetailSheet.automaticTierAccessibilityLabel(tier) == expected.accessibility)
  }

  @MainActor
  @Test("Multi route subtitles summarize observed and missing output selectors")
  func multiRouteSubtitle() {
    func subtitle(_ selected: Set<String>, _ devices: [(uid: String, name: String)]) -> String? {
      let app = MixerContractFixture.app(
        id: "com.example.player", name: "Player", selectionMode: .multi,
        selectedDeviceUIDs: selected)
      let fixture = MixerContractFixture(
        apps: [app],
        outputDevices: devices.map { MixerContractFixture.device(uid: $0.uid, name: $0.name) })
      return MixerAppRowPresentation(app: app, bindings: fixture.bindings).subtitle
    }

    #expect(subtitle([], []) == "Multi")
    #expect(subtitle(["uid-1"], [("uid-1", "Studio Display")]) == "Multi · Studio Display")
    #expect(
      subtitle(
        ["uid-1", "uid-2"],
        [("uid-1", "Studio Display"), ("uid-2", "MacBook Speakers")]) == "Multi · 2 devices")
    #expect(
      subtitle(["uid-1", "uid-missing"], [("uid-1", "Studio Display")])
        == "Multi · Studio Display · 1 unavailable")
    #expect(subtitle(["uid-a", "uid-b"], []) == "Multi · 2 unavailable")
  }

  @MainActor
  @Test("The multi route tooltip keeps its own literal mode and count format")
  func multiRouteLabel() {
    let app = MixerContractFixture.app(
      id: "com.example.player", name: "Player", selectionMode: .multi,
      selectedDeviceUIDs: ["uid-1"])
    let fixture = MixerContractFixture(
      apps: [app],
      outputDevices: [MixerContractFixture.device(uid: "uid-1", name: "Studio Display")])
    #expect(fixture.bindings.routeLabel(app) == "Multi · 1 device — Studio Display")
  }

  @MainActor
  @Test("Popup device names read the default output and input, never the first row")
  func popupDeviceNames() {
    let absent = MixerContractFixture()
    let absentSemantics = MixerPopupSemantics(
      snapshot: absent.snapshot, bindings: absent.bindings)
    #expect(absentSemantics.outputName == "No Output")
    #expect(absentSemantics.inputName == "No Input")

    let fixture = MixerContractFixture(
      outputDevices: [
        MixerContractFixture.device(uid: "out-1", name: "First Output"),
        MixerContractFixture.device(uid: "out-2", name: "Second Output", isDefault: true),
      ],
      inputDevices: [
        MixerContractFixture.device(uid: "in-1", name: "First Input"),
        MixerContractFixture.device(uid: "in-2", name: "Second Input", isDefault: true),
      ])
    let semantics = MixerPopupSemantics(snapshot: fixture.snapshot, bindings: fixture.bindings)
    #expect(semantics.outputName == "Second Output")
    #expect(semantics.inputName == "Second Input")
  }

  @MainActor
  @Test("Browse and edit semantics keep ignored apps out of the visible cohort")
  func popupBrowseAndEditSemantics() {
    let active = MixerContractFixture.app(id: "app-active", name: "Active")
    let ignored = MixerContractFixture.app(
      id: "app-ignored", name: "Ignored", isActive: false, isIgnored: true)

    let empty = MixerContractFixture()
    let emptySemantics = MixerPopupSemantics(
      snapshot: empty.snapshot, bindings: empty.bindings)
    #expect(emptySemantics.apps.isEmpty)
    #expect(emptySemantics.ignoredApps.isEmpty)
    #expect(emptySemantics.emptyState == "No apps playing audio")
    #expect(emptySemantics.ignoredBadge == nil)
    #expect(emptySemantics.ignoredEmptyHint == nil)

    let ignoredOnly = MixerContractFixture(apps: [ignored])
    let ignoredOnlySemantics = MixerPopupSemantics(
      snapshot: ignoredOnly.snapshot, bindings: ignoredOnly.bindings)
    #expect(ignoredOnlySemantics.apps.isEmpty)
    #expect(ignoredOnlySemantics.ignoredApps.map(\.id) == ["app-ignored"])
    #expect(ignoredOnlySemantics.emptyState == "No apps playing audio")
    #expect(ignoredOnlySemantics.ignoredBadge == "1 ignored")
    #expect(ignoredOnlySemantics.ignoredEmptyHint == "1 ignored · edit to manage")

    let mixed = MixerContractFixture(apps: [active, ignored])
    let browse = MixerPopupSemantics(snapshot: mixed.snapshot, bindings: mixed.bindings)
    #expect(browse.apps.map(\.id) == ["app-active"])
    #expect(browse.ignoredApps.map(\.id) == ["app-ignored"])
    #expect(browse.emptyState == nil)
    #expect(browse.ignoredBadge == "1 ignored")
    #expect(browse.ignoredEmptyHint == nil)

    let editing = MixerPopupSemantics(
      snapshot: mixed.snapshot, bindings: mixed.bindings, editing: true)
    #expect(editing.apps.map(\.id) == ["app-active"])
    #expect(editing.ignoredApps.map(\.id) == ["app-ignored"])
    #expect(editing.emptyState == nil)
    #expect(editing.ignoredBadge == nil)
    #expect(editing.ignoredEmptyHint == nil)
  }

  @MainActor
  @Test("Capture notices retain their message and map only the two actionable labels")
  func captureNoticeCopy() {
    let message = "Capture needs an explicit retry."
    let cases: [(action: MixerCaptureNotice.Action?, label: String?)] = [
      (nil, nil),
      (.requestPermission, "Allow System Audio"),
      (.openSettings, "Open System Settings"),
      (.retryCapture, nil),
    ]
    for (action, label) in cases {
      let fixture = MixerContractFixture(
        captureNotice: MixerCaptureNotice(message: message, action: action))
      let notice = MixerPopupSemantics(
        snapshot: fixture.snapshot, bindings: fixture.bindings
      ).captureNotice
      #expect(notice?.message == message)
      #expect(notice?.actionLabel == label)
    }

    let absent = MixerContractFixture()
    #expect(
      MixerPopupSemantics(snapshot: absent.snapshot, bindings: absent.bindings).captureNotice
        == nil)
  }

  @Test("Live drag exchanges the dragged row with the row under the pointer")
  func dragSwapsRowsBeforeDrop() {
    let uids = ["first", "second", "third", "fourth"]
    #expect(
      MixerBindings.swappedPriority(uids, dragged: "first", target: "third")
        == ["third", "second", "first", "fourth"])
    #expect(
      MixerBindings.swappedPriority(uids, dragged: "second", target: "fourth")
        == ["first", "fourth", "third", "second"])
    #expect(MixerBindings.swappedPriority(uids, dragged: "second", target: "second") == uids)
    #expect(MixerBindings.swappedPriority(uids, dragged: "missing", target: "first") == uids)
  }
}
