import CoreGraphics
import FineTuneDomain

struct PopupDimensions: Equatable, Sendable {
  let width: CGFloat
  let contentPadding: CGFloat
  let maxContentHeight: CGFloat
}

extension MenuBarPopupSize {
  var dimensions: PopupDimensions {
    let metrics: (CGFloat, CGFloat, CGFloat)
    switch self {
    case .compact: metrics = (470, 12, 560)
    case .comfortable: metrics = (510, 16, 660)
    case .spacious: metrics = (560, 20, 760)
    }
    return PopupDimensions(
      width: metrics.0, contentPadding: metrics.1, maxContentHeight: metrics.2)
  }
}
