import AppKit
import Testing

/// Measures the selected badge in the real production bitmap, in square points, not view structure.
@MainActor
func badgeAccentArea(in rect: CGRect, bitmap: NSBitmapImageRep, host: NSView) throws -> CGFloat {
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
      if color.blueComponent > color.redComponent + 0.25
        && color.blueComponent > color.greenComponent + 0.1
      {
        count += 1
      }
    }
  }
  return CGFloat(count) / scaleX / scaleY
}
