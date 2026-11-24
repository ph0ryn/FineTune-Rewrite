import AppKit
import SwiftUI

/// Plain settings chrome: native window background, spacing, and native controls only.
struct SettingsScrollView<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxl) {
        content
      }
      .padding(DesignTokens.Spacing.xl)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SettingsSection<Content: View>: View {
  let title: String
  private let content: Content

  init(
    _ title: String, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text(title).font(.system(size: 13, weight: .semibold))
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        content
      }
    }
  }
}

struct SettingsNativeToggle: NSViewRepresentable {
  @Binding var isOn: Bool
  let title: String
  var isEnabled = true

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSSwitch {
    let control = NSSwitch()
    control.target = context.coordinator
    control.action = #selector(Coordinator.valueChanged(_:))
    return control
  }

  func updateNSView(_ control: NSSwitch, context: Context) {
    context.coordinator.parent = self
    control.state = isOn ? .on : .off
    control.isEnabled = isEnabled
    control.setAccessibilityLabel(title)
  }

  @MainActor
  final class Coordinator: NSObject {
    var parent: SettingsNativeToggle

    init(parent: SettingsNativeToggle) {
      self.parent = parent
    }

    @objc func valueChanged(_ sender: NSSwitch) {
      parent.isOn = sender.state == .on
    }
  }
}

struct SettingsTabSelector: NSViewRepresentable {
  @Binding var selection: SettingsTab

  func makeNSView(context: Context) -> SettingsTabSelectorView {
    SettingsTabSelectorView()
  }

  func updateNSView(_ nsView: SettingsTabSelectorView, context: Context) {
    nsView.onSelect = { selection = $0 }
    nsView.selection = selection
  }
}

@MainActor
final class SettingsTabSelectorView: NSView {
  var selection: SettingsTab = .general {
    didSet { refreshSelection() }
  }
  var onSelect: ((SettingsTab) -> Void)?
  private var buttons: [SettingsTab: NSButton] = [:]
  private let underline = NSView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(underline)
    underline.wantsLayer = true
    underline.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
    for tab in SettingsTab.allCases {
      let button = NSButton(title: tab.title, target: nil, action: nil)
      button.isBordered = false
      button.focusRingType = .none
      button.target = self
      button.action = #selector(selectTab(_:))
      addSubview(button)
      buttons[tab] = button
    }
    refreshSelection()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    var width: CGFloat = 0
    for tab in SettingsTab.allCases {
      let button = tryRequireButton(tab)
      width += ceil(button.attributedTitle.size().width) + 24
    }
    width += CGFloat(SettingsTab.allCases.count - 1) * DesignTokens.Spacing.xs
    return NSSize(width: width, height: 36)
  }

  override func layout() {
    super.layout()
    var x: CGFloat = 0
    for tab in SettingsTab.allCases {
      let button = tryRequireButton(tab)
      let width = ceil(button.attributedTitle.size().width) + 24
      button.setFrameSize(NSSize(width: width, height: 28))
      button.frame.origin = NSPoint(x: x, y: 4)
      if tab == selection {
        underline.frame = NSRect(x: x, y: 0, width: width, height: 2)
      }
      x += width + DesignTokens.Spacing.xs
    }
  }

  private func refreshSelection() {
    for (tab, button) in buttons {
      let font = NSFont.systemFont(
        ofSize: 13, weight: tab == selection ? .semibold : .regular)
      let color = NSColor.labelColor.withAlphaComponent(tab == selection ? 1 : 0.65)
      button.attributedTitle = NSAttributedString(
        string: tab.title, attributes: [.font: font, .foregroundColor: color])
    }
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func tryRequireButton(_ tab: SettingsTab) -> NSButton {
    guard let button = buttons[tab] else {
      preconditionFailure("Missing settings tab button: \(tab)")
    }
    return button
  }

  @objc private func selectTab(_ sender: NSButton) {
    guard let tab = buttons.first(where: { $0.value === sender })?.key else { return }
    onSelect?(tab)
    selection = tab
  }
}

struct SettingsRow<Content: View>: View {
  let title: String
  let description: String
  private let content: Content

  init(
    _ title: String, description: String, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.description = description
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.lg) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(title).font(DesignTokens.Typography.rowName)
        Text(description).font(DesignTokens.Typography.rowDescription)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: DesignTokens.Spacing.md)
      content
    }
    .frame(maxWidth: .infinity)
  }
}
