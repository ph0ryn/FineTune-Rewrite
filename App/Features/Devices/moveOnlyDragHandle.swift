import AppKit
import SwiftUI

/// AppKit drag source that advertises only `.move`, so macOS does not show the copy (`+`) cursor
/// that SwiftUI's `onDrag` adds by default.
struct MoveOnlyDragHandle: NSViewRepresentable {
  let uid: String
  let label: String
  let onBegin: () -> Void
  let onEnd: () -> Void

  func makeNSView(context: Context) -> MoveOnlyDragHandleView {
    let view = MoveOnlyDragHandleView()
    view.uid = uid
    view.label = label
    view.onBegin = onBegin
    view.onEnd = onEnd
    return view
  }

  func updateNSView(_ nsView: MoveOnlyDragHandleView, context: Context) {
    nsView.uid = uid
    nsView.label = label
    nsView.onBegin = onBegin
    nsView.onEnd = onEnd
  }
}

final class MoveOnlyDragHandleView: NSView, NSDraggingSource {
  var uid = ""
  var label = ""
  var onBegin: (() -> Void)?
  var onEnd: (() -> Void)?

  private let imageView: NSImageView = {
    let view = NSImageView()
    view.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
    view.imageScaling = .scaleProportionallyUpOrDown
    view.contentTintColor = .tertiaryLabelColor
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    installImageView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    installImageView()
  }

  private func installImageView() {
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString(uid, forType: .string)
    let dragItem = NSDraggingItem(pasteboardWriter: item)
    dragItem.setDraggingFrame(bounds, contents: nil)
    dragItem.imageComponentsProvider = { [weak self] in
      guard let self else { return [] }
      let image = Self.dragPreview(label: label)
      let component = NSDraggingImageComponent(key: .icon)
      component.contents = image
      component.frame = NSRect(origin: .zero, size: image.size)
      return [component]
    }
    onBegin?()
    beginDraggingSession(with: [dragItem], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .move
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation
  ) {
    onEnd?()
  }

  private static func dragPreview(label: String) -> NSImage {
    let text = NSAttributedString(
      string: label,
      attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
    let textSize = text.size()
    let size = NSSize(width: textSize.width + 16, height: textSize.height + 8)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.controlBackgroundColor.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
    text.draw(at: NSPoint(x: 8, y: 4))
    image.unlockFocus()
    return image
  }
}
