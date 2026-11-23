// No-render contracts for keyboard state transitions and effect-to-action routing.
import FineTuneDomain
import Testing

@testable import FineTune

@Suite("Presentation contract: mixer keyboard state and routing")
@MainActor
struct MixerKeyboardContractTests {
  @Test("A first action key wakes and acts on the default row in the same press")
  func keyboardWakeAndAct() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    #expect(
      keyboard.process(.right(shift: true), navigation: navigation, defaultOutputUID: nil)
        == .adjust(.app(persistenceID: "player"), isUp: true, shift: true))
    #expect(keyboard.selectedRow == .app(persistenceID: "player"))
  }

  @Test("An arrow wakes without moving, then traverses without wrapping")
  func keyboardWakeAndTraverse() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(
      activeDevices: [], appPersistenceIDs: ["first", "second"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    #expect(keyboard.process(.down, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.selectedRow == .app(persistenceID: "first"))
    _ = keyboard.process(.down, navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.selectedRow == .app(persistenceID: "second"))
    _ = keyboard.process(.down, navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.selectedRow == .app(persistenceID: "second"))
  }

  @Test("Pointer activity yields the selection and any draft only while navigation is engaged")
  func pointerActivityYieldsSelection() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.down, navigation: navigation, defaultOutputUID: nil)
    _ = keyboard.process(.digit(8), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.isEngaged && keyboard.selectedRow == .app(persistenceID: "player"))
    keyboard.yieldToPointer()
    #expect(!keyboard.isEngaged && keyboard.selectedRow == nil && keyboard.percentageDraft == nil)
    keyboard.yieldToPointer()
    #expect(!keyboard.isEngaged && keyboard.selectedRow == nil)
  }

  @Test("Keyboard percentage entry is a transient draft until Return")
  func keyboardPercentageDraft() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(8), navigation: navigation, defaultOutputUID: nil)
    _ = keyboard.process(.digit(0), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.percentageDraft == "80")
    #expect(
      keyboard.process(.activate, navigation: navigation, defaultOutputUID: nil)
        == .setPercentage(.app(persistenceID: "player"), 80))
    #expect(keyboard.percentageDraft == nil)
  }

  @Test("Escape cancels percentage entry before closing the popup")
  func keyboardPercentageCancel() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(3), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.process(.cancel, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.percentageDraft == nil)
    #expect(keyboard.process(.cancel, navigation: navigation, defaultOutputUID: nil) == .close)
  }

  @Test("Space is consumed during percentage entry rather than committing or activating")
  func spaceDoesNotCommitPercentage() {
    let navigation = PopupKeyboardNavModel()
    navigation.syncOrder(activeDevices: [], appPersistenceIDs: ["player"], isEditingPriority: false)
    var keyboard = MixerKeyboardState()
    _ = keyboard.process(.digit(8), navigation: navigation, defaultOutputUID: nil)
    #expect(keyboard.process(.space, navigation: navigation, defaultOutputUID: nil) == .none)
    #expect(keyboard.percentageDraft == "8")
  }

  @Test("Keyboard router toggles EQ expansion, switches tabs, and forwards scoped actions")
  func keyboardRouterDispatchesActions() {
    let source = MixerTestSource()
    var scope: MixerDeviceScope = .output
    var expandedAppID: String?

    MixerKeyboardRouter.perform(
      .activate(.app(persistenceID: "com.example.player")),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    #expect(expandedAppID == "com.example.player")
    #expect(source.events.isEmpty)

    MixerKeyboardRouter.perform(
      .activate(.app(persistenceID: "com.example.player")),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    #expect(expandedAppID == nil)

    MixerKeyboardRouter.perform(
      .activate(.device(uid: "output-uid")),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    #expect(source.events == ["default"])
    #expect(source.lastDeviceScope == .output && source.lastDeviceUID == "output-uid")

    source.events.removeAll()
    MixerKeyboardRouter.perform(
      .switchDeviceTab, scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    #expect(scope == .input)

    MixerKeyboardRouter.perform(
      .adjust(.device(uid: "input-uid"), isUp: true, shift: true),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    MixerKeyboardRouter.perform(
      .toggleMute(.app(persistenceID: "com.example.player")),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    MixerKeyboardRouter.perform(
      .setPercentage(.app(persistenceID: "com.example.player"), 50),
      scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)
    MixerKeyboardRouter.perform(
      .close, scope: &scope, expandedAppID: &expandedAppID, bindings: source.bindings)

    #expect(
      source.events == [
        "device-step:input:input-uid:true:true",
        "app-mute",
        "app-volume",
        "close",
      ])
    #expect(source.lastBool == true)
    #expect(abs((source.lastGain ?? 0) - 0.25) < 0.000_001)
  }
}
