// No-render contracts for app route menu logic, row subtitles, and edit-mode warning suppression.
import FineTuneDomain
import Testing

@testable import FineTune

@Suite("Presentation contract: route menu, subtitles, and warning visibility")
@MainActor
struct MixerRouteMenuContractTests {
  @Test("Route menu delegates single, multi and default choices without optimistic selection")
  func routeMenuActions() throws {
    let source = MixerTestSource()
    source.snapshot.apps[0].isActive = true
    source.snapshot.apps[0].selectionMode = .single
    source.snapshot.apps[0].isFollowingDefault = true
    source.snapshot.apps[0].selectedDeviceUIDs = []

    var hidden = source.snapshot.outputDevices[0]
    hidden.device = AudioDevice(
      id: 109, uid: "hidden-uid", name: "Hidden", icon: nil, supportsAutoEQ: false)
    hidden.isDefault = false
    hidden.isHidden = true
    source.snapshot.outputDevices.append(hidden)

    func makeModel() -> MixerAppRouteMenuModel {
      MixerAppRouteMenuModel(
        app: source.snapshot.apps[0], bindings: source.bindings,
        dismiss: { source.events.append("dismiss") })
    }
    var model = makeModel()
    #expect(model.visibleDevices.map(\.id) == ["output-uid"])
    let output = try #require(model.visibleDevices.first)

    model.selectMode(.single)
    #expect(source.events.isEmpty, "The already observed single mode changes nothing")
    model.selectMode(.multi)
    #expect(source.events == ["route"])
    #expect(source.lastMode == .multi && source.lastUIDs == [])
    #expect(source.snapshot.apps[0].selectionMode == .single)
    source.events.removeAll()

    source.snapshot.apps[0].selectionMode = .multi
    source.snapshot.apps[0].isFollowingDefault = false
    source.snapshot.apps[0].selectedDeviceUIDs = ["output-uid"]
    model = makeModel()
    #expect(model.isSystemAudioDisabled)
    #expect(model.isDeviceSelected(output))
    model.selectSystemAudio()
    #expect(source.events.isEmpty, "System Audio is unavailable in multi mode")
    model.selectDevice(output)
    #expect(source.events == ["route"])
    #expect(source.lastMode == .multi && source.lastUIDs == [])
    source.events.removeAll()
    // The fake command did not change observations: another tap must use the still-selected UID.
    model.selectDevice(output)
    #expect(source.lastUIDs == [])
    #expect(source.events == ["route"])
    source.events.removeAll()

    source.snapshot.apps[0].selectionMode = .single
    source.snapshot.apps[0].selectedDeviceUIDs = []
    model = makeModel()
    #expect(!model.isSystemAudioDisabled)
    model.selectDevice(output)
    #expect(source.events == ["route", "dismiss"])
    #expect(source.lastMode == .single && source.lastUIDs == ["output-uid"])
    source.events.removeAll()
    model.selectSystemAudio()
    #expect(source.events == ["follow-default", "dismiss"])
    #expect(source.lastAppID == "com.example.player")
  }

  @Test("Nondefault and unavailable single-mode subtitles name the output or missing UID")
  func routingSubtitle() throws {
    let source = MixerTestSource()
    source.snapshot.apps[0].isActive = true
    source.snapshot.apps[0].isFollowingDefault = false
    source.snapshot.apps[0].selectedDeviceUIDs = ["output-uid"]
    let resolved = MixerAppRowPresentation(app: source.snapshot.apps[0], bindings: source.bindings)
    #expect(resolved.subtitle == "Output")

    source.snapshot.apps[0].selectedDeviceUIDs = ["missing-device"]
    let unavailable = MixerAppRowPresentation(
      app: source.snapshot.apps[0], bindings: source.bindings)
    #expect(unavailable.subtitle == "Unavailable (missing-device)")
    #expect(source.events.isEmpty)
  }

  @Test("App warnings stay out of edit mode and reflect updates on exit while global errors remain")
  func editingHidesAppWarningsUntilExit() {
    let source = MixerTestSource()
    source.snapshot.error = "Unable to save settings."
    source.snapshot.apps[0].isActive = true
    source.snapshot.apps[0].isFollowingDefault = false
    source.snapshot.apps[0].selectedDeviceUIDs = ["output-uid"]
    source.snapshot.apps[0].routeStatus = "Current audio route failed"

    let browseBefore = MixerAppRowPresentation(
      app: source.snapshot.apps[0], bindings: source.bindings, isEditing: false)
    let browseSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings, editing: false)
    #expect(browseBefore.routeStatus == "Current audio route failed")
    #expect(browseBefore.subtitle == "Output")
    #expect(browseSemantics.globalError == "Unable to save settings.")

    let editInitial = MixerAppRowPresentation(
      app: source.snapshot.apps[0], bindings: source.bindings, isEditing: true)
    let editSemantics = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings, editing: true)
    #expect(editInitial.routeStatus == nil)
    #expect(editInitial.subtitle == nil)
    #expect(editSemantics.globalError == "Unable to save settings.")

    source.snapshot.apps[0].routeStatus = "Current audio cleanup failed"
    let editUpdated = MixerAppRowPresentation(
      app: source.snapshot.apps[0], bindings: source.bindings, isEditing: true)
    #expect(editUpdated.routeStatus == nil)

    source.snapshot.error = nil
    let editNoError = MixerPopupSemantics(
      snapshot: source.snapshot, bindings: source.bindings, editing: true)
    #expect(editNoError.globalError == nil)

    source.snapshot.error = "Unable to save settings."
    let browseAfter = MixerAppRowPresentation(
      app: source.snapshot.apps[0], bindings: source.bindings, isEditing: false)
    #expect(browseAfter.routeStatus == "Current audio cleanup failed")
    #expect(browseAfter.subtitle == "Output")
    #expect(source.events.isEmpty)
  }

  @Test("Edit mode lists inactive unpinned apps separately from ignored apps and hides badge")
  func editModeInactiveUnpinnedApps() {
    let activePinned = MixerContractFixture.app(id: "app-Alpha", name: "Alpha", isPinned: true)
    let inactiveUnpinned = MixerContractFixture.app(
      id: "app-Gamma", name: "Gamma", isActive: false, isPinned: false)
    let ignored = MixerContractFixture.app(
      id: "app-Hidden", name: "Hidden", isActive: true, isIgnored: true)
    let fixture = MixerContractFixture(apps: [activePinned, inactiveUnpinned, ignored])

    let browse = MixerPopupSemantics(snapshot: fixture.snapshot, bindings: fixture.bindings)
    #expect(browse.apps.map(\.id) == ["app-Alpha"])
    #expect(browse.ignoredBadge == "1 ignored")

    let editing = MixerPopupSemantics(
      snapshot: fixture.snapshot, bindings: fixture.bindings, editing: true)
    #expect(editing.apps.map(\.id) == ["app-Alpha", "app-Gamma"])
    #expect(editing.ignoredApps.map(\.id) == ["app-Hidden"])
    #expect(editing.ignoredBadge == nil)
    #expect(editing.ignoredEmptyHint == nil)
  }
}
