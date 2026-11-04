import AppKit
import FineTuneDomain
import FineTunePlatform
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MixerView: View {
  let read: () -> MixerSnapshot
  let actions: MixerActions
  let profiles: MixerProfileInterface
  @State private var scope: MixerDeviceScope = .output
  @State private var isEditing = false
  @State private var expandedAppID: String?
  @State private var inspected: DeviceSelection?
  @State private var iconSelection: DeviceSelection?
  @State private var profileSelection: DeviceSelection?
  @State private var draggedDeviceUID: String?
  @State private var navigation = PopupKeyboardNavModel()
  @State private var keyboard = MixerKeyboardState()
  @FocusState private var anchorFocused: Bool

  private struct DeviceSelection: Identifiable {
    let scope: MixerDeviceScope
    let uid: String
    var id: String { "\(scope.rawValue):\(uid)" }
  }

  private var bindings: MixerBindings { MixerBindings(read: read, actions: actions) }
  private var rowIDs: [PopupKeyboardNavModel.RowID] {
    bindings.devices(scope: scope, editing: isEditing).map { .device(uid: $0.id) }
      + bindings.visibleApps(editing: isEditing).map { .app(persistenceID: $0.id) }
  }

  var body: some View {
    let snapshot = read()
    content
      .padding(snapshot.settings.popupSize.dimensions.contentPadding)
      .frame(width: snapshot.settings.popupSize.dimensions.width)
      .background(.regularMaterial)
      .background(WindowAppearanceBridge(appearance: snapshot.settings.appearance.nsAppearance))
      .preferredColorScheme(snapshot.settings.appearance.swiftUIColorScheme)
      .environment(\.appearancePreference, snapshot.settings.appearance)
      .focusable().focused($anchorFocused)
      .onKeyPress { handleKey($0) }
      .onAppear {
        syncNavigation()
        anchorFocused = true
      }
      .onChange(of: rowIDs) { _, _ in syncNavigation() }
      .onChange(of: scope) { _, _ in
        keyboard = MixerKeyboardState()
        draggedDeviceUID = nil
        syncNavigation()
      }
      .popover(item: $inspected) { selection in inspector(selection) }
      .popover(item: $iconSelection) { selection in iconPicker(selection) }
      .popover(item: $profileSelection) { selection in
        if let device = bindings.devices(scope: .output, editing: true).first(where: {
          $0.id == selection.uid
        }) {
          MixerAutoEQPanel(
            deviceUID: device.id, deviceName: device.device.name, interface: profiles)
        } else {
          Text("This device is no longer connected.").padding()
        }
      }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack {
        Picker("Devices", selection: $scope) {
          ForEach(MixerDeviceScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize()
        Spacer()
        Button(isEditing ? "Done" : "Edit") {
          isEditing.toggle()
          keyboard = MixerKeyboardState()
          draggedDeviceUID = nil
          syncNavigation()
        }
        .buttonStyle(.plain)
        Button(action: actions.openSettings) { Image(systemName: "gearshape") }
          .buttonStyle(.plain).accessibilityLabel("Settings")
      }
      if let notice = read().captureNotice {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Label(notice.message, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.rowDescription)
          Spacer(minLength: 0)
          if let action = notice.action {
            switch action {
            case .requestPermission:
              Button("Allow System Audio", action: actions.requestCapturePermission)
            case .openSettings:
              Button("Open System Settings", action: actions.openCaptureSettings)
            }
          }
        }
        .controlSize(.small).foregroundStyle(.orange)
      }
      if let error = read().error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            deviceSection
            if scope == .output && !isEditing {
              MixerBluetoothSection(read: { read().backend.bluetooth }, actions: actions.backend)
            }
            Divider().padding(.vertical, DesignTokens.Spacing.xs)
            Text("APPLICATIONS").font(DesignTokens.Typography.sectionHeader)
              .tracking(DesignTokens.Typography.sectionHeaderTracking)
              .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
            let apps = bindings.visibleApps(editing: isEditing)
            if apps.isEmpty {
              Text("Apps playing audio appear here.")
                .font(DesignTokens.Typography.rowName).foregroundStyle(.secondary)
                .padding(.vertical, DesignTokens.Spacing.md)
            }
            ForEach(apps) { app in
              MixerAppRow(
                app: app, bindings: bindings, isEditing: isEditing,
                percentageDraft: keyboard.selectedRow == .app(persistenceID: app.id)
                  ? keyboard.percentageDraft : nil,
                isEQExpanded: Binding(
                  get: { expandedAppID == app.id }, set: { expandedAppID = $0 ? app.id : nil })
              )
              .id(PopupKeyboardNavModel.RowID.app(persistenceID: app.id))
              .background(selectionBackground(.app(persistenceID: app.id)))
            }
          }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: read().settings.popupSize.dimensions.maxContentHeight)
        .onChange(of: keyboard.selectedRow) { _, row in
          if let row { proxy.scrollTo(row, anchor: .center) }
        }
      }
    }
  }

  private var deviceSection: some View {
    let sectionScope = scope
    let devices = bindings.devices(scope: sectionScope, editing: isEditing)
    return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      if devices.isEmpty {
        Text("No \(scope.rawValue) devices connected.")
          .font(DesignTokens.Typography.rowName).foregroundStyle(.secondary)
          .padding(.vertical, DesignTokens.Spacing.md)
      }
      ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
        if isEditing {
          HStack(spacing: DesignTokens.Spacing.sm) {
            TextField(
              "Priority",
              value: Binding(
                get: { index + 1 }, set: { moveDevice(device.id, to: $0 - 1, scope: sectionScope) }),
              format: .number
            )
            .frame(width: 28).accessibilityLabel("Priority for \(device.device.name)")
            deviceContent(device)
            Button {
              actions.device.setHidden(
                sectionScope, device.id, !bindings.current(device, scope: sectionScope).isHidden)
            } label: {
              Image(systemName: device.isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(device.isHidden ? "Show" : "Hide") \(device.device.name)")
          }
          .opacity(device.isHidden ? 0.6 : 1)
          .onDrag {
            draggedDeviceUID = device.id
            return NSItemProvider(object: device.id as NSString)
          }
          .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            guard let uid = draggedDeviceUID else { return false }
            moveDevice(uid, to: index, scope: sectionScope)
            draggedDeviceUID = nil
            return true
          }
        } else {
          deviceContent(device)
            .id(PopupKeyboardNavModel.RowID.device(uid: device.id))
            .background(selectionBackground(.device(uid: device.id)))
        }
      }
    }
  }

  private func deviceContent(_ device: MixerDevicePresentation) -> some View {
    let renderScope = scope
    return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        bindings.deviceRow(device, scope: renderScope)
        if renderScope == .output && device.device.supportsAutoEQ && !isEditing {
          Button("AutoEQ") {
            profileSelection = DeviceSelection(scope: renderScope, uid: device.id)
          }
          .buttonStyle(.plain).font(DesignTokens.Typography.pickerText)
          .accessibilityLabel("Headphone correction for \(device.device.name)")
        }
        Button {
          inspected = DeviceSelection(scope: renderScope, uid: device.id)
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.plain).accessibilityLabel("Details for \(device.device.name)")
        if isEditing {
          Button {
            iconSelection = DeviceSelection(scope: renderScope, uid: device.id)
          } label: {
            Image(systemName: "paintbrush.pointed")
          }
          .buttonStyle(.plain).accessibilityLabel("Icon for \(device.device.name)")
        }
      }
      if let draft = keyboard.percentageDraft, keyboard.selectedRow == .device(uid: device.id) {
        Text("Volume: \(draft)%").font(DesignTokens.Typography.percentage)
          .foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .trailing)
      }
      if let error = device.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(DesignTokens.Typography.caption).foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder private func inspector(_ selection: DeviceSelection) -> some View {
    if let row = bindings.devices(scope: selection.scope, editing: true).first(where: {
      $0.id == selection.uid
    }) {
      DeviceDetailSheet(
        device: row.device, transportType: row.transport, autoDetectedTier: row.automaticBackend,
        currentOverride: row.volumeOverride, isInput: selection.scope == .input,
        allowsVolumeOverride: selection.scope == .output,
        onOverrideChange: selection.scope == .output
          ? { actions.device.setVolumeOverride(row.id, $0) } : nil,
        onDismiss: { inspected = nil }
      )
      .frame(width: 380)
    } else {
      Text("This device is no longer connected.").padding()
    }
  }

  @ViewBuilder private func iconPicker(_ selection: DeviceSelection) -> some View {
    if let row = bindings.devices(scope: selection.scope, editing: true).first(where: {
      $0.id == selection.uid
    }) {
      let automaticSymbol = row.automaticSymbol(scope: selection.scope)
      DeviceIconPicker(
        deviceName: row.device.name, transport: row.transport, automaticSymbol: automaticSymbol,
        // Only our generated fallback has a known symbol identity; supplied NSImages are opaque.
        automaticIsSymbol: row.device.icon == nil, currentOverride: row.iconOverride,
        suggestedLeadingSymbol: selection.scope == .input ? automaticSymbol : nil,
        onSelect: { actions.device.setIcon(row.id, $0) }
      )
      .padding().frame(width: 340)
    } else {
      Text("This device is no longer connected.").padding()
    }
  }

  private func moveDevice(_ uid: String, to proposedIndex: Int, scope: MixerDeviceScope) {
    var uids = bindings.devices(scope: scope, editing: true).map(\.id)
    guard let index = uids.firstIndex(of: uid) else { return }
    uids.remove(at: index)
    uids.insert(uid, at: max(0, min(uids.count, proposedIndex)))
    actions.device.setPriority(scope, uids)
  }

  private func selectionBackground(_ row: PopupKeyboardNavModel.RowID) -> some View {
    RoundedRectangle(cornerRadius: 10)
      .fill(
        keyboard.isEngaged && keyboard.selectedRow == row ? Color.accentColor.opacity(0.12) : .clear
      )
  }

  private func syncNavigation() {
    navigation.syncOrder(
      activeDevices: bindings.devices(scope: scope, editing: false).map(\.device),
      appPersistenceIDs: bindings.visibleApps(editing: false).map(\.id),
      isEditingPriority: isEditing)
    if let selected = keyboard.selectedRow, !navigation.orderedRowIDs.contains(selected) {
      keyboard = MixerKeyboardState()
    }
  }

  private func handleKey(_ key: KeyPress) -> KeyPress.Result {
    guard !isEditing, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
    let input: MixerKeyboardInput?
    switch key.key {
    case .upArrow: input = .up
    case .downArrow: input = .down
    case .leftArrow: input = .left(shift: key.modifiers.contains(.shift))
    case .rightArrow: input = .right(shift: key.modifiers.contains(.shift))
    case .return: input = .activate
    case .space: input = .space
    case .tab: input = .deviceTab
    case .escape: input = .cancel
    case "m": input = .mute
    default:
      if key.characters == "\u{7f}" || key.key == .delete {
        input = keyboard.percentageDraft == nil ? nil : .delete
      } else if key.phase == .down, key.characters.count == 1,
        key.modifiers.intersection([.command, .control, .option]).isEmpty,
        let value = Int(key.characters), (0...9).contains(value)
      {
        input = .digit(value)
      } else {
        input = nil
      }
    }
    guard let input else { return keyboard.percentageDraft == nil ? .ignored : .handled }
    let effect = keyboard.process(
      input, navigation: navigation,
      defaultOutputUID: bindings.devices(scope: scope, editing: false).first(where: \.isDefault)?.id
    )
    if input == .deviceTab && effect == .none && keyboard.percentageDraft == nil { return .ignored }
    perform(effect)
    return .handled
  }

  private func perform(_ effect: MixerKeyboardEffect) {
    switch effect {
    case .none: break
    case .close: actions.close()
    case .switchDeviceTab: scope = scope == .output ? .input : .output
    case .adjust(let row, let isUp, let shift):
      switch row {
      case .app(let id): actions.app.stepVolume(id, isUp, shift)
      case .device(let uid): actions.device.stepVolume(scope, uid, isUp, shift)
      }
    case .activate(let row):
      switch row {
      case .device(let uid): actions.device.setDefault(scope, uid)
      case .app(let id): expandedAppID = expandedAppID == id ? nil : id
      }
    case .toggleMute(let row):
      switch row {
      case .app(let id):
        if let app = bindings.visibleApps(editing: false).first(where: { $0.id == id }) {
          actions.app.setMute(id, !app.isMuted)
        }
      case .device(let uid): bindings.toggleDeviceMute(scope: scope, uid: uid)
      }
    case .setPercentage(let row, let percentage):
      let fraction = Double(percentage) / 100
      switch row {
      case .app(let id): actions.app.setVolume(id, VolumeMapping.sliderToGain(fraction))
      case .device(let uid):
        if let device = bindings.devices(scope: scope, editing: false).first(where: { $0.id == uid }
        ) {
          actions.device.setVolume(
            scope, uid, DeviceRow.sliderToVolume(fraction, backend: device.backend))
        }
      }
    }
  }
}
