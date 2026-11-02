import XCTest
@testable import EkagrachitCore

final class GeometryTests: XCTestCase {
    let screen = Rect(x: 0, y: 0, width: 1440, height: 900)

    private func assertCovers(_ rects: [Rect], screen: Rect, hole: Rect?, file: StaticString = #filePath, line: UInt = #line) {
        let holeOnScreen = hole.flatMap { screen.intersection($0.integral) }
        // No overlap with the hole
        for r in rects {
            if let h = holeOnScreen { XCTAssertNil(r.intersection(h), "\(r) overlaps hole", file: file, line: line) }
            XCTAssertNotNil(screen.intersection(r), file: file, line: line)
        }
        // Pairwise disjoint
        for i in rects.indices { for j in rects.indices where i < j { XCTAssertNil(rects[i].intersection(rects[j]), file: file, line: line) } }
        // Total area = screen - hole
        let total = rects.map(\.area).reduce(0, +)
        XCTAssertEqual(total, screen.area - (holeOnScreen?.area ?? 0), accuracy: 0.5, file: file, line: line)
    }

    func testHoleInTheMiddleYieldsFourRects() {
        let hole = Rect(x: 200, y: 100, width: 800, height: 600)
        let r = OverlayGeometry.coverRects(screen: screen, hole: hole)
        XCTAssertEqual(r.count, 4)
        assertCovers(r, screen: screen, hole: hole)
    }

    func testHoleTouchingEdges() {
        for hole in [Rect(x: 0, y: 0, width: 700, height: 900), Rect(x: 0, y: 25, width: 1440, height: 875), Rect(x: 1000, y: 0, width: 440, height: 300)] {
            assertCovers(OverlayGeometry.coverRects(screen: screen, hole: hole), screen: screen, hole: hole)
        }
    }

    func testHoleCoveringScreen() {
        XCTAssertEqual(OverlayGeometry.coverRects(screen: screen, hole: Rect(x: -10, y: -10, width: 2000, height: 2000)), [])
    }

    func testNoHoleOrHoleOnAnotherScreenCoversEverything() {
        XCTAssertEqual(OverlayGeometry.coverRects(screen: screen, hole: nil), [screen])
        XCTAssertEqual(OverlayGeometry.coverRects(screen: screen, hole: Rect(x: 1500, y: 0, width: 400, height: 400)), [screen])
    }

    func testWindowSpanningTwoScreens() {
        let second = Rect(x: 1440, y: 0, width: 1920, height: 1080)
        let hole = Rect(x: 1200, y: 100, width: 600, height: 500)
        assertCovers(OverlayGeometry.coverRects(screen: screen, hole: hole), screen: screen, hole: hole)
        assertCovers(OverlayGeometry.coverRects(screen: second, hole: hole), screen: second, hole: hole)
    }

    func testFractionalHoleIsRoundedOutward() {
        let hole = Rect(x: 100.4, y: 100.6, width: 300.2, height: 200.2)
        let r = OverlayGeometry.coverRects(screen: screen, hole: hole)
        assertCovers(r, screen: screen, hole: hole)
        XCTAssertTrue(r.allSatisfy { $0.x == $0.x.rounded() && $0.y == $0.y.rounded() })
    }

    func testFlipIsAnInvolution() {
        let r = Rect(x: 10, y: 20, width: 300, height: 200)
        let flipped = OverlayGeometry.flip(r, primaryHeight: 900)
        XCTAssertEqual(flipped, Rect(x: 10, y: 680, width: 300, height: 200))
        XCTAssertEqual(OverlayGeometry.flip(flipped, primaryHeight: 900), r)
    }
}
