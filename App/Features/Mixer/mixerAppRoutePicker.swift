// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Ronit Singh
// Derived from FineTune/Views/Components/{DevicePicker,ModeToggle}.swift at
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Modified 2026-11-05: native popover lifecycle and observed selection through existing common actions.

import AppKit
import FineTuneDomain
import SwiftUI

/// Copy rendered by the route menu; `MixerAppRouteMenu` reads these values directly so the mode
/// buttons and System Audio row use the same strings the parity tests assert.
struct MixerAppRouteCopy: Equatable {
  var singleMode = "Single"
  var multiMode = "Multi"
  var systemAudio = "System Audio"
  var followsDefault = "Follows macOS default"
  var unavailableInMulti = "Not available in multi mode"

  func modeLabel(_ mode: DeviceSelectionMode) -> String {
    mode == .single ? singleMode : multiMode
  }

  func systemAudioDetail(isMulti: Bool) -> String {
    isMulti ? unavailableInMulti : followsDefault
  }
}

@MainActor
struct MixerAppRoutePicker: View {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  @State private var isPresented = false
  @State private var isHovered = false

  private var selectedDevices: [MixerDevicePresentation] {
    bindings.read().outputDevices.filter { app.selectedDeviceUIDs.contains($0.id) }
  }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      triggerIcon
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
            .fill(Color.primary.opacity(isPresented ? 0.12 : (isHovered ? 0.08 : 0)))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(bindings.routeLabel(app))
    .accessibilityLabel("Output for \(app.name): \(bindings.routeLabel(app))")
    .onHover { isHovered = $0 }
    .animation(DesignTokens.Animation.hover, value: isHovered)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      MixerAppRouteMenu(app: app, bindings: bindings, dismiss: { isPresented = false })
    }
  }

  @ViewBuilder private var triggerIcon: some View {
    if app.selectionMode == .multi {
      if let first = selectedDevices.first {
        deviceIcon(first)
          .overlay(alignment: .bottomTrailing) {
            Text("\(selectedDevices.count)").font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 0.5)
              .background(DesignTokens.Colors.accentPrimary, in: Capsule())
              .offset(x: 4, y: 3)
          }
      } else {
        Image(systemName: "hifispeaker.2.fill").font(.system(size: 16))
          .symbolRenderingMode(.hierarchical)
      }
    } else if app.isFollowingDefault {
      Image(systemName: "globe").font(.system(size: 15)).symbolRenderingMode(.hierarchical)
    } else if let device = selectedDevices.first {
      deviceIcon(device)
    } else {
      Image(systemName: "speaker.wave.2").font(.system(size: 15))
        .symbolRenderingMode(.hierarchical)
    }
  }

  @ViewBuilder private func deviceIcon(_ device: MixerDevicePresentation) -> some View {
    if let icon = bindings.deviceIcon(device, scope: .output) {
      Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
    } else {
      Image(systemName: "speaker.wave.2").font(.system(size: 15))
        .symbolRenderingMode(.hierarchical)
    }
  }

  static func subtitle(_ app: MixerAppPresentation, bindings: MixerBindings) -> String? {
    if app.selectionMode == .single {
      return app.isFollowingDefault ? nil : bindings.routeLabel(app)
    }
    let devices = bindings.read().outputDevices.filter { app.selectedDeviceUIDs.contains($0.id) }
    let missingCount = app.selectedDeviceUIDs.subtracting(Set(devices.map(\.id))).count
    let summary: String
    switch devices.count {
    case 0: summary = "Multi"
    case 1: summary = "Multi · \(devices[0].device.name)"
    default: summary = "Multi · \(devices.count) devices"
    }
    return missingCount == 0 ? summary : "\(summary) · \(missingCount) unavailable"
  }
}

/// Pure route-menu selection and dismissal logic shared by `MixerAppRouteMenu` and contract tests.
@MainActor
struct MixerAppRouteMenuModel {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  let dismiss: () -> Void

  var current: MixerAppPresentation { bindings.current(app) }

  var visibleDevices: [MixerDevicePresentation] {
    bindings.read().outputDevices.filter { !$0.isHidden }
  }

  var isSystemAudioDisabled: Bool { current.selectionMode == .multi }

  func isDeviceSelected(_ device: MixerDevicePresentation) -> Bool {
    !current.isFollowingDefault && current.selectedDeviceUIDs.contains(device.id)
  }

  func selectMode(_ mode: DeviceSelectionMode) {
    let observed = current
    if observed.selectionMode != mode {
      bindings.selectRoute(observed, mode: mode, uids: observed.selectedDeviceUIDs)
    }
  }

  func selectSystemAudio() {
    let observed = current
    guard observed.selectionMode != .multi else { return }
    bindings.followDefault(observed)
    dismiss()
  }

  func selectDevice(_ device: MixerDevicePresentation) {
    let observed = current
    var uids = observed.selectionMode == .multi ? observed.selectedDeviceUIDs : []
    if observed.selectionMode == .multi && uids.contains(device.id) {
      uids.remove(device.id)
    } else {
      uids.insert(device.id)
    }
    bindings.selectRoute(observed, mode: observed.selectionMode, uids: uids)
    if observed.selectionMode == .single { dismiss() }
  }
}

/// Selection is always observed. Only whether the native popover is open is local UI state.
@MainActor
struct MixerAppRouteMenu: View {
  let app: MixerAppPresentation
  let bindings: MixerBindings
  let dismiss: () -> Void
  var copy = MixerAppRouteCopy()
  @State private var hoveredMode: DeviceSelectionMode?

  private var menuModel: MixerAppRouteMenuModel {
    MixerAppRouteMenuModel(app: app, bindings: bindings, dismiss: dismiss)
  }

  var body: some View {
    let current = menuModel.current
    let devices = menuModel.visibleDevices
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        modeButton(.single, label: copy.modeLabel(.single))
        modeButton(.multi, label: copy.modeLabel(.multi))
      }
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6).strokeBorder(
          DesignTokens.Colors.glassBorder, lineWidth: 0.5)
      )
      .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 4)
      Divider().padding(.horizontal, 6)
      ScrollView(.vertical) {
        VStack(spacing: 2) {
          MixerAppRouteOption(
            name: copy.systemAudio, icon: nil, isSystemAudio: true,
            detail: copy.systemAudioDetail(isMulti: menuModel.isSystemAudioDisabled),
            isSelected: current.isFollowingDefault, isMulti: menuModel.isSystemAudioDisabled,
            isDefault: false
          ) {
            menuModel.selectSystemAudio()
          }
          ForEach(devices) { device in
            MixerAppRouteOption(
              name: device.device.name, icon: bindings.deviceIcon(device, scope: .output),
              isSystemAudio: false, detail: nil,
              isSelected: menuModel.isDeviceSelected(device),
              isMulti: menuModel.isSystemAudioDisabled, isDefault: device.isDefault
            ) {
              menuModel.selectDevice(device)
            }
          }
        }
        .padding(.vertical, 6).padding(.horizontal, 5)
      }
      .scrollIndicators(.hidden)
      .frame(height: min(220, CGFloat(devices.count + 1) * 28 + 10))
    }
    .frame(width: 210)
  }

  private func modeButton(_ mode: DeviceSelectionMode, label: String) -> some View {
    let selected = menuModel.current.selectionMode == mode
    return Button {
      menuModel.selectMode(mode)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 10))
          .foregroundStyle(
            selected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
        Text(label).font(.system(size: 11, weight: selected ? .medium : .regular))
          .foregroundStyle(
            selected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(
            selected
              ? Color.accentColor.opacity(0.15)
              : (hoveredMode == mode ? DesignTokens.Colors.hoverSurface : .clear))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(label) output for \(app.name)")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { hoveredMode = $0 ? mode : nil }
    .animation(DesignTokens.Animation.hover, value: hoveredMode)
  }
}

@MainActor
private struct MixerAppRouteOption: View {
  let name: String
  let icon: NSImage?
  let isSystemAudio: Bool
  let detail: String?
  let isSelected: Bool
  let isMulti: Bool
  let isDefault: Bool
  let action: () -> Void
  @State private var isHovered = false

  private var isDisabled: Bool { isSystemAudio && isMulti }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: isMulti ? (isSelected ? "checkmark.square.fill" : "square") : "checkmark")
          .font(.system(size: 11, weight: .semibold)).frame(width: 16)
          .foregroundStyle(
            isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary
          )
          .opacity(isMulti || isSelected ? 1 : 0)
        if let icon {
          Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
          Image(systemName: isSystemAudio ? "globe" : "speaker.wave.2")
            .font(.system(size: 13)).frame(width: 16)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(name).lineLimit(1)
          if let detail {
            Text(detail)
              .font(DesignTokens.Typography.caption).foregroundStyle(
                DesignTokens.Colors.textTertiary)
          }
        }
        Spacer(minLength: 0)
        if isDefault {
          Image(systemName: "star.fill").font(.system(size: 9))
            .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
      }
      .font(.system(size: 11))
      .foregroundStyle(isDisabled ? DesignTokens.Colors.textQuaternary : .primary)
      .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isHovered && !isDisabled ? Color.accentColor.opacity(0.15) : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .onHover { isHovered = $0 }
    .accessibilityLabel(name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
