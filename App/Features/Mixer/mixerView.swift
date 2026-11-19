// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived application section presentation from FineTune/Views/MenuBarPopupView.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: common rewrite bindings, observed app ordering and non-scrolling popup ownership.

import AppKit
import FineTuneDomain
import FineTunePlatform
import SwiftUI
import UniformTypeIdentifiers

/// Text and section state the popup renders. `MixerView` reads this same value, so tests assert the
/// production projection instead of re-deriving fixture state.
struct MixerPopupSemantics {
  struct CaptureNotice: Equatable {
    var message: String
    var actionLabel: String?
  }

  var outputName: String
  var inputName: String
  /// Raw applications for the requested mode, in render order. `MixerAppRow` derives its own text.
  var apps: [MixerAppPresentation]
  /// Ignored applications the edit grid lists separately; browse-mode badge and hint count them.
  var ignoredApps: [MixerAppPresentation]
  var sectionHeader: String
  var emptyState: String?
  var ignoredBadge: String?
  var ignoredEmptyHint: String?
  var captureNotice: CaptureNotice?
  var globalError: String?

  @MainActor
  init(snapshot: MixerSnapshot, bindings: MixerBindings, editing: Bool = false) {
    let visible = bindings.visibleApps(editing: editing).filter { !$0.isIgnored }
    let ignored = bindings.visibleApps(editing: true).filter(\.isIgnored)
    outputName = snapshot.outputDevices.first(where: \.isDefault)?.device.name ?? "No Output"
    inputName = snapshot.inputDevices.first(where: \.isDefault)?.device.name ?? "No Input"
    apps = visible
    ignoredApps = ignored
    sectionHeader = "APPS"
    emptyState = !editing && visible.isEmpty ? "No apps playing audio" : nil
    ignoredBadge = !editing && !ignored.isEmpty ? "\(ignored.count) ignored" : nil
    ignoredEmptyHint =
      !editing && visible.isEmpty && !ignored.isEmpty
      ? "\(ignored.count) ignored · edit to manage" : nil
    captureNotice = snapshot.captureNotice.map { notice in
      let actionLabel: String?
      switch notice.action {
      case .requestPermission: actionLabel = "Allow System Audio"
      case .openSettings: actionLabel = "Open System Settings"
      case .retryCapture, nil: actionLabel = nil
      }
      return CaptureNotice(message: notice.message, actionLabel: actionLabel)
    }
    globalError = snapshot.error
  }
}

/// The production two-column edit grid. Rendering this value uses the same columns, spacing and
/// row composition as the popup instead of recomputing a column width in the test.
@MainActor
struct MixerAppEditGrid: View {
  static let columns = [
    GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
    GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
  ]

  let apps: [MixerAppPresentation]
  let bindings: MixerBindings

  var body: some View {
    LazyVGrid(columns: Self.columns, spacing: DesignTokens.Spacing.xs) {
      ForEach(apps) { app in
        // Edit mode resets keyboard state and handles only Escape, so rows show no draft or focus.
        MixerAppRow(
          app: app, bindings: bindings, isEditing: true,
          percentageDraft: nil,
          isEQExpanded: .constant(false)
        )
        .id(PopupKeyboardNavModel.RowID.app(persistenceID: app.id))
      }
    }
  }
}

@MainActor
struct MixerView: View {
  let read: () -> MixerSnapshot
  let actions: MixerActions
  let profiles: MixerProfileInterface
  let quit: () -> Void
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

  init(
    read: @escaping () -> MixerSnapshot, actions: MixerActions, profiles: MixerProfileInterface,
    quit: @escaping () -> Void,
    initialExpandedAppID: String? = nil
  ) {
    self.read = read
    self.actions = actions
    self.profiles = profiles
    self.quit = quit
    _expandedAppID = State(initialValue: initialExpandedAppID)
  }

  private struct DeviceSelection: Identifiable {
    let scope: MixerDeviceScope
    let uid: String
    var id: String { "\(scope.rawValue):\(uid)" }
  }

  /// Event-time bindings only. A view body must use the snapshot read in `body` instead.
  private var eventBindings: MixerBindings {
    MixerBindings(snapshot: read(), actions: actions, readFresh: read)
  }

  private func rowIDs(in bindings: MixerBindings) -> [PopupKeyboardNavModel.RowID] {
    bindings.devices(scope: scope, editing: isEditing).map { .device(uid: $0.id) }
      + bindings.visibleApps(editing: isEditing).map { .app(persistenceID: $0.id) }
  }

  var body: some View {
    let snapshot = read()
    let bindings = MixerBindings(snapshot: snapshot, actions: actions, readFresh: read)
    let rowIDs = rowIDs(in: bindings)
    content(snapshot: snapshot, bindings: bindings)
      .padding(snapshot.settings.popupSize.dimensions.contentPadding)
      .frame(width: snapshot.settings.popupSize.dimensions.width)
      .fixedSize(horizontal: false, vertical: true)
      .background {
        // Native glass contains this transparent content on newer systems.
        if #unavailable(macOS 26) { Rectangle().fill(.regularMaterial) }
      }
      .background(WindowAppearanceBridge(appearance: snapshot.settings.appearance.nsAppearance))
      .preferredColorScheme(snapshot.settings.appearance.swiftUIColorScheme)
      .environment(\.appearancePreference, snapshot.settings.appearance)
      // Suppress only the anchor's outline; actual controls keep their own focus effects.
      .focusable().focusEffectDisabled(anchorFocused).focused($anchorFocused)
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
      .popover(item: $inspected) { selection in inspector(selection, bindings: eventBindings) }
      .popover(item: $iconSelection) { selection in iconPicker(selection, bindings: eventBindings) }
      .popover(item: $profileSelection) { selection in
        if let device = eventBindings.devices(scope: .output, editing: true).first(where: {
          $0.id == selection.uid
        }) {
          MixerAutoEQPanel(
            deviceUID: device.id, deviceName: device.device.name, interface: profiles)
        } else {
          Text("This device is no longer connected.").padding()
        }
      }
  }

  private func content(snapshot: MixerSnapshot, bindings: MixerBindings) -> some View {
    let semantics = MixerPopupSemantics(
      snapshot: snapshot, bindings: bindings, editing: isEditing)
    return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      MixerHeader(
        scope: $scope, isEditing: isEditing,
        outputName: semantics.outputName,
        inputName: semantics.inputName,
        edit: {
          isEditing.toggle()
          keyboard = MixerKeyboardState()
          draggedDeviceUID = nil
          syncNavigation()
        }, retryAudio: actions.requestCapturePermission, settings: actions.openSettings)
      if let notice = semantics.captureNotice {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Label(notice.message, systemImage: "exclamationmark.triangle")
            .font(DesignTokens.Typography.rowDescription)
          Spacer(minLength: 0)
          if let label = notice.actionLabel {
            switch snapshot.captureNotice?.action {
            case .requestPermission:
              Button(label, action: actions.requestCapturePermission)
            case .openSettings:
              Button(label, action: actions.openCaptureSettings)
            case .retryCapture, nil:
              EmptyView()
            }
          }
        }
        .controlSize(.small).foregroundStyle(.orange)
      }
      if let error = semantics.globalError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.orange)
      }
      deviceSection(bindings: bindings)
      if scope == .output && isEditing {
        MixerBluetoothSection(
          read: {
            var current = read().backend.bluetooth
            let connectedNames = Set(read().outputDevices.map { $0.device.name })
            current.paired.removeAll { connectedNames.contains($0.name) }
            return current
          }, actions: actions.backend)
      }
      Divider().padding(.vertical, DesignTokens.Spacing.xs)
      applicationsSection(semantics: semantics, bindings: bindings)
      Divider().padding(.vertical, DesignTokens.Spacing.xs)
      MixerFooter(quit: quit)
    }
  }

  private func applicationsSection(semantics: MixerPopupSemantics, bindings: MixerBindings)
    -> some View
  {
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(semantics.sectionHeader).font(DesignTokens.Typography.sectionHeader)
          .tracking(DesignTokens.Typography.sectionHeaderTracking)
        Spacer()
        if let badge = semantics.ignoredBadge {
          Text(badge).font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
      }
      .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
      .padding(.bottom, DesignTokens.Spacing.xs)
      if isEditing {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          MixerAppEditGrid(apps: semantics.apps, bindings: bindings)
          if !semantics.ignoredApps.isEmpty {
            Divider().padding(.vertical, DesignTokens.Spacing.xs)
            Text("IGNORED").font(DesignTokens.Typography.sectionHeader)
              .tracking(DesignTokens.Typography.sectionHeaderTracking)
              .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
              .padding(.bottom, DesignTokens.Spacing.xs)
            MixerAppEditGrid(apps: semantics.ignoredApps, bindings: bindings)
          }
        }
      } else if let emptyState = semantics.emptyState {
        HStack {
          Spacer()
          VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "speaker.slash").font(.title)
              .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text(emptyState).font(.callout)
              .foregroundStyle(DesignTokens.Colors.textSecondary)
            if let hint = semantics.ignoredEmptyHint {
              Text(hint).font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
          }
          Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(semantics.apps) { app in appRow(app, bindings: bindings) }
        }
      }
    }
  }

  private func appRow(_ app: MixerAppPresentation, bindings: MixerBindings) -> some View {
    MixerAppRow(
      app: app, bindings: bindings, isEditing: isEditing,
      percentageDraft: keyboard.selectedRow == .app(persistenceID: app.id)
        ? keyboard.percentageDraft : nil,
      isEQExpanded: Binding(
        get: { expandedAppID == app.id }, set: { expandedAppID = $0 ? app.id : nil }),
      isFocused: keyboard.isEngaged && keyboard.selectedRow == .app(persistenceID: app.id)
    )
    .id(PopupKeyboardNavModel.RowID.app(persistenceID: app.id))
  }

  private func deviceSection(bindings: MixerBindings) -> some View {
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
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
              .accessibilityLabel("Drag to reorder \(device.device.name)")
            TextField(
              "Priority",
              value: Binding(
                get: { index + 1 },
                set: {
                  moveDevice(device.id, to: $0 - 1, scope: sectionScope, bindings: bindings)
                }),
              format: .number
            )
            .frame(width: 28).accessibilityLabel("Priority for \(device.device.name)")
            deviceContent(device, bindings: bindings)
            if device.isDefault {
              Text("DEFAULT").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            }
            Button {
              actions.device.setHidden(
                sectionScope, device.id, !bindings.current(device, scope: sectionScope).isHidden)
            } label: {
              Image(systemName: device.isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain).disabled(device.isDefault)
            .accessibilityLabel("\(device.isHidden ? "Show" : "Hide") \(device.device.name)")
          }
          .opacity(device.isHidden ? 0.6 : 1)
          .onDrag {
            draggedDeviceUID = device.id
            return NSItemProvider(object: device.id as NSString)
          }
          .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            guard let uid = draggedDeviceUID else { return false }
            moveDevice(uid, to: index, scope: sectionScope, bindings: bindings)
            draggedDeviceUID = nil
            return true
          }
        } else {
          deviceContent(device, bindings: bindings)
            .id(PopupKeyboardNavModel.RowID.device(uid: device.id))
            .background(selectionBackground(.device(uid: device.id)))
        }
      }
    }
  }

  private func deviceContent(_ device: MixerDevicePresentation, bindings: MixerBindings)
    -> some View
  {
    let renderScope = scope
    let profile = profiles.read(device.id)
    let subtitle =
      renderScope == .output && !isEditing
      ? profile.selection.flatMap {
        DeviceRow.autoEQSubtitle(
          profileName: MixerProfileBindings(deviceUID: device.id, interface: profiles)
            .selectionLabel,
          isEnabled: $0.isEnabled)
      } : nil
    return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        bindings.deviceRow(device, scope: renderScope, autoEQSubtitle: subtitle)
        // AutoEQ availability must not change the width offered to DeviceRow.
        Group {
          if renderScope == .output && device.device.supportsAutoEQ && !isEditing {
            Button("AutoEQ") {
              profileSelection = DeviceSelection(scope: renderScope, uid: device.id)
            }
            .buttonStyle(.plain).font(DesignTokens.Typography.pickerText)
            .accessibilityLabel("Headphone correction for \(device.device.name)")
          } else {
            Color.clear.frame(height: 0).accessibilityHidden(true)
          }
        }
        .frame(width: DesignTokens.Dimensions.percentageWidth)
        Button {
          inspected = DeviceSelection(scope: renderScope, uid: device.id)
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.plain).frame(width: DesignTokens.Dimensions.minTouchTarget)
        .accessibilityLabel("Details for \(device.device.name)")
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

  @ViewBuilder private func inspector(_ selection: DeviceSelection, bindings: MixerBindings)
    -> some View
  {
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

  @ViewBuilder private func iconPicker(_ selection: DeviceSelection, bindings: MixerBindings)
    -> some View
  {
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

  private func moveDevice(
    _ uid: String, to proposedIndex: Int, scope: MixerDeviceScope, bindings: MixerBindings
  ) {
    var uids = bindings.devices(scope: scope, editing: true).map(\.id)
    guard let index = uids.firstIndex(of: uid) else { return }
    uids.remove(at: index)
    uids.insert(uid, at: max(0, min(uids.count, proposedIndex)))
    actions.device.setPriority(scope, uids)
  }

  private func selectionBackground(_ row: PopupKeyboardNavModel.RowID) -> some View {
    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
      .fill(
        keyboard.isEngaged && keyboard.selectedRow == row ? Color.accentColor.opacity(0.12) : .clear
      )
      // Give the highlight breathing room without shifting the shared device control columns.
      .padding(.horizontal, -DesignTokens.Spacing.sm)
  }

  private func syncNavigation() {
    let bindings = eventBindings
    navigation.syncOrder(
      activeDevices: bindings.devices(scope: scope, editing: false).map(\.device),
      appPersistenceIDs: bindings.visibleApps(editing: false).map(\.id),
      isEditingPriority: isEditing)
    if let selected = keyboard.selectedRow, !navigation.orderedRowIDs.contains(selected) {
      keyboard = MixerKeyboardState()
    }
  }

  private func handleKey(_ key: KeyPress) -> KeyPress.Result {
    if key.key == .escape {
      if keyboard.percentageDraft != nil {
        _ = keyboard.process(.cancel, navigation: navigation, defaultOutputUID: nil)
      } else if inspected != nil {
        inspected = nil
      } else if isEditing {
        isEditing = false
        draggedDeviceUID = nil
        syncNavigation()
      } else if expandedAppID != nil {
        expandedAppID = nil
      } else {
        actions.close()
      }
      return .handled
    }
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
      defaultOutputUID: eventBindings.devices(scope: scope, editing: false).first(
        where: \.isDefault)?.id
    )
    if input == .deviceTab && effect == .none && keyboard.percentageDraft == nil { return .ignored }
    perform(effect)
    return .handled
  }

  private func perform(_ effect: MixerKeyboardEffect) {
    MixerKeyboardRouter.perform(
      effect, scope: &scope, expandedAppID: &expandedAppID, bindings: eventBindings)
  }
}

/// Pure dispatcher for keyboard effects emitted by `MixerKeyboardState`.
@MainActor
enum MixerKeyboardRouter {
  static func perform(
    _ effect: MixerKeyboardEffect,
    scope: inout MixerDeviceScope,
    expandedAppID: inout String?,
    bindings: MixerBindings
  ) {
    switch effect {
    case .none: break
    case .close: bindings.actions.close()
    case .switchDeviceTab: scope = scope == .output ? .input : .output
    case .adjust(let row, let isUp, let shift):
      switch row {
      case .app(let id): bindings.actions.app.stepVolume(id, isUp, shift)
      case .device(let uid): bindings.actions.device.stepVolume(scope, uid, isUp, shift)
      }
    case .activate(let row):
      switch row {
      case .device(let uid): bindings.actions.device.setDefault(scope, uid)
      case .app(let id): expandedAppID = expandedAppID == id ? nil : id
      }
    case .toggleMute(let row):
      switch row {
      case .app(let id):
        if let app = bindings.visibleApps(editing: false).first(where: { $0.id == id }) {
          bindings.actions.app.setMute(id, !app.isMuted)
        }
      case .device(let uid): bindings.toggleDeviceMute(scope: scope, uid: uid)
      }
    case .setPercentage(let row, let percentage):
      let fraction = Double(percentage) / 100
      switch row {
      case .app(let id): bindings.actions.app.setVolume(id, VolumeMapping.sliderToGain(fraction))
      case .device(let uid):
        if let device = bindings.devices(scope: scope, editing: false).first(where: {
          $0.id == uid
        }) {
          bindings.actions.device.setVolume(
            scope, uid, DeviceRow.sliderToVolume(fraction, backend: device.backend))
        }
      }
    }
  }
}
