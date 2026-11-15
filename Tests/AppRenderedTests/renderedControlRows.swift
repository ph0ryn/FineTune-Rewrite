import CoreGraphics

/// Actual rendered proxy frames grouped into visual rows, top-to-bottom in the host's orientation
/// and left-to-right within a row. A frame joins the current row when its vertical extent overlaps
/// that row's first frame; otherwise it starts a new row. Endpoint-touching extents do not overlap.
///
/// Shared by the rendered suites only. It is intentionally internal so the helper does not become
/// package API just to deduplicate this algorithm.
func renderedControlRows(_ frames: [CGRect], isFlipped: Bool) -> [[CGRect]] {
  let top: (CGRect) -> CGFloat = { isFlipped ? $0.minY : -$0.maxY }
  let ordered = frames.sorted {
    top($0) < top($1) || (top($0) == top($1) && $0.minX < $1.minX)
  }
  var rows: [[CGRect]] = []
  for frame in ordered {
    // Frames whose vertical extents overlap belong to the same rendered row.
    if let reference = rows.last?.first, frame.minY < reference.maxY,
      frame.maxY > reference.minY
    {
      rows[rows.count - 1].append(frame)
    } else {
      rows.append([frame])
    }
  }
  return rows.map { $0.sorted { $0.minX < $1.minX } }
}
