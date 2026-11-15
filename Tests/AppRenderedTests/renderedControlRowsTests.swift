// Pure geometry for the shared rendered-row grouping. No AppKit view, window or bitmap is created.
import CoreGraphics
import Testing

@Suite("Rendered control rows: pure geometry")
struct RenderedControlRowsTests {
  private func frame(
    _ x: CGFloat, _ y: CGFloat, width: CGFloat = 20, height: CGFloat = 20
  ) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

  @Test("Empty input produces no rows in either orientation")
  func emptyInput() {
    #expect(renderedControlRows([], isFlipped: true).isEmpty)
    #expect(renderedControlRows([], isFlipped: false).isEmpty)
  }

  @Test("Controls with the same vertical extent share a row, left to right")
  func sameExtentSharesRow() {
    let rows = renderedControlRows([frame(40, 10), frame(0, 10)], isFlipped: true)
    #expect(rows.count == 1)
    #expect(rows.first?.map(\.minX) == [0, 40])
  }

  @Test("Endpoint-touching vertical extents remain separate rows")
  func endpointTouchingStaysSeparate() {
    let rows = renderedControlRows([frame(0, 0), frame(0, 20)], isFlipped: true)
    #expect(rows.count == 2)
    #expect(rows.map { $0.first?.minY } == [0, 20])
  }

  @Test("A one-point vertical overlap joins the row")
  func onePointOverlapJoins() {
    let rows = renderedControlRows([frame(0, 0), frame(30, 19)], isFlipped: true)
    #expect(rows.count == 1)
    #expect(rows.first?.map(\.minX) == [0, 30])
  }

  @Test("A two-point vertical gap separates rows")
  func twoPointGapSeparates() {
    let rows = renderedControlRows([frame(0, 0), frame(0, 22)], isFlipped: true)
    #expect(rows.count == 2)
  }

  @Test("A two-point vertical offset is not a two-point gap for tall controls")
  func twoPointOffsetOverlapsTallControls() {
    // 40pt-tall controls offset by 2pt still overlap vertically and share one rendered row.
    let tall = renderedControlRows(
      [frame(0, 0, height: 40), frame(40, 2, height: 40)], isFlipped: true)
    #expect(tall.count == 1)
    #expect(tall.first?.map(\.minX) == [0, 40])
    // The same 2pt displacement measured as a gap between 20pt-tall controls stays two rows.
    let short = renderedControlRows([frame(0, 0), frame(0, 22)], isFlipped: true)
    #expect(short.count == 2)
  }

  @Test("Non-flipped hosts return visual top-to-bottom order")
  func nonFlippedVisualOrder() {
    let rows = renderedControlRows([frame(0, 0), frame(0, 40)], isFlipped: false)
    #expect(rows.count == 2)
    #expect(rows.map { $0.first?.minY } == [40, 0])
  }

  @Test("Left-to-right order is independent of the host orientation")
  func leftToRightOrder() {
    let frames = [frame(60, 5), frame(0, 5), frame(30, 5)]
    #expect(renderedControlRows(frames, isFlipped: true).first?.map(\.minX) == [0, 30, 60])
    #expect(renderedControlRows(frames, isFlipped: false).first?.map(\.minX) == [0, 30, 60])
  }
}
