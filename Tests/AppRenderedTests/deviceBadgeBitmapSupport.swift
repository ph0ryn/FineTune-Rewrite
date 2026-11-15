import AppKit
import SwiftUI
import Testing

@testable import FineTune

/// The production badge keeps its documented 28pt circular footprint in both observed states.
@MainActor
func badgeFittingSize(isSelected: Bool, icon: NSImage? = nil) -> CGSize {
  NSHostingView(
    rootView: DeviceBadge(
      icon: icon, isSelected: isSelected, fallbackSymbol: "speaker.wave.2.fill")
  ).fittingSize
}

/// Counts matching rendered pixels in a badge-sized rect. Used only for the documented accent and
/// white-glyph styling, which SwiftUI draws without exposing a public view value.
@MainActor
func badgePixelArea(
  in rect: CGRect, bitmap: NSBitmapImageRep, host: NSView,
  matching predicate: (NSColor) -> Bool
) throws -> CGFloat {
  let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
  let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
  let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
  let xs = Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX)
  let ys = Int(top * scaleY)..<Int((top + rect.height) * scaleY)
  try #require(xs.lowerBound >= 0 && xs.upperBound <= bitmap.pixelsWide)
  try #require(ys.lowerBound >= 0 && ys.upperBound <= bitmap.pixelsHigh)
  var count = 0
  for y in ys {
    for x in xs {
      let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
      if predicate(color) { count += 1 }
    }
  }
  return CGFloat(count) / scaleX / scaleY
}

/// The selected accent fill; zero when the badge is in its mono state.
@MainActor
func badgeAccentArea(in rect: CGRect, bitmap: NSBitmapImageRep, host: NSView) throws -> CGFloat {
  try badgePixelArea(in: rect, bitmap: bitmap, host: host) { color in
    color.blueComponent > color.redComponent + 0.25
      && color.blueComponent > color.greenComponent + 0.1
  }
}

/// The white glyph drawn on the selected accent fill. The rect must stay inside the circle so the
/// background cannot contribute white pixels.
@MainActor
func badgeWhiteGlyphArea(in rect: CGRect, bitmap: NSBitmapImageRep, host: NSView) throws
  -> CGFloat
{
  try badgePixelArea(in: rect, bitmap: bitmap, host: host) { color in
    color.redComponent > 0.97 && color.greenComponent > 0.97 && color.blueComponent > 0.97
  }
}

@MainActor
func leafDescendants(of view: NSView) -> [NSView] {
  view.subviews.flatMap { [$0] + leafDescendants(of: $0) }
}

/// Native proxies SwiftUI creates for actual buttons. Their frames are the rendered button bounds,
/// not a formula; `KeyViewProxy` identifies keyboard-loop controls, while `FocusRing` draws the
/// focus effect for those controls. Route-menu rows can request KeyViewProxy-only identities. A
/// `.focusable()` container also creates a full-size proxy that contains every control, so container
/// frames are dropped before the per-button pair is merged. A caller clicks each real control once.
@MainActor
func nativeButtonProxyFrames(
  in root: NSView, minimumWidth: CGFloat = 0, includeFocusRingProxies: Bool = true
) -> [CGRect] {
  let raw = leafDescendants(of: root).compactMap { view -> CGRect? in
    let className = String(describing: type(of: view))
    guard
      className.contains("KeyViewProxy")
        || (includeFocusRingProxies && className.contains("FocusRing"))
    else { return nil }
    let frame = root.convert(view.bounds, from: view)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return frame
  }
  var unique: [CGRect] = []
  for frame in raw where !unique.contains(where: { $0.equalTo(frame) }) {
    unique.append(frame)
  }
  // The focusable container's proxy contains every button proxy; it is not a button frame.
  let controls = unique.filter { frame in
    !unique.contains { other in
      other != frame && frame.insetBy(dx: -0.5, dy: -0.5).contains(other)
    }
  }
  var merged: [CGRect] = []
  for frame in controls.filter({ $0.width >= minimumWidth }).sorted(by: {
    $0.minX < $1.minX || ($0.minX == $1.minX && $0.minY < $1.minY)
  }) {
    if let index = merged.firstIndex(where: { $0.intersects(frame) }) {
      merged[index] = merged[index].union(frame)
    } else {
      merged.append(frame)
    }
  }
  return merged
}
