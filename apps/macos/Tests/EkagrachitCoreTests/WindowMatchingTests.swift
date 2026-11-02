import XCTest
@testable import EkagrachitCore

final class WindowMatchingTests: XCTestCase {
    let chrome: Int32 = 500
    let me: Int32 = 42
    let popupBounds = Rect(x: 100, y: 80, width: 1200, height: 800)

    func testFindsPopupByPidAndBounds() {
        let candidates = [
            WindowInfo(number: 10, pid: chrome, layer: 0, bounds: Rect(x: 0, y: 25, width: 1440, height: 875), onScreen: true),
            WindowInfo(number: 30, pid: chrome, layer: 0, bounds: Rect(x: 101, y: 80, width: 1200, height: 799), onScreen: true),
            WindowInfo(number: 31, pid: 777, layer: 0, bounds: popupBounds, onScreen: true),
            WindowInfo(number: 32, pid: chrome, layer: 3, bounds: popupBounds, onScreen: true),
        ]
        XCTAssertEqual(WindowMatching.findFocusWindow(candidates: candidates, browserPid: chrome, reported: popupBounds)?.number, 30)
    }

    func testPrefersNewestOfIdenticalWindows() {
        let c = [
            WindowInfo(number: 12, pid: chrome, layer: 0, bounds: popupBounds, onScreen: true),
            WindowInfo(number: 40, pid: chrome, layer: 0, bounds: popupBounds, onScreen: true),
        ]
        XCTAssertEqual(WindowMatching.findFocusWindow(candidates: c, browserPid: chrome, reported: popupBounds)?.number, 40)
    }

    func testNoMatch() {
        let c = [WindowInfo(number: 12, pid: chrome, layer: 0, bounds: Rect(x: 0, y: 0, width: 10, height: 10), onScreen: true)]
        XCTAssertNil(WindowMatching.findFocusWindow(candidates: c, browserPid: chrome, reported: popupBounds))
    }

    var focus: WindowInfo { WindowInfo(number: 30, pid: chrome, layer: 0, bounds: popupBounds, onScreen: true) }

    func assess(above: [WindowInfo] = [], pid: Int32? = 500, bundle: String? = "com.google.Chrome", focus f: WindowInfo?? = nil) -> FocusAssessment {
        FocusPolicy.assess(focus: f ?? focus, above: above, frontmostPid: pid, frontmostBundleID: bundle, browserPid: chrome, ownPid: me)
    }

    func testFocused() {
        XCTAssertEqual(assess(), .focused)
    }

    func testOtherAppActive() {
        guard case .lost = assess(pid: 900, bundle: "com.tinyspeck.slackmacgap") else { return XCTFail() }
    }

    func testOtherChromeWindowInFront() {
        let other = WindowInfo(number: 50, pid: chrome, layer: 0, bounds: Rect(x: 0, y: 25, width: 1440, height: 875), onScreen: true)
        guard case .lost = assess(above: [other]) else { return XCTFail() }
    }

    func testChromeChildSurfacesInsideTheWindowAreFine() {
        let menu = WindowInfo(number: 51, pid: chrome, layer: 0, bounds: Rect(x: 300, y: 200, width: 200, height: 300), onScreen: true)
        let floating = WindowInfo(number: 52, pid: 900, layer: 3, bounds: popupBounds, onScreen: true)
        let invisible = WindowInfo(number: 53, pid: 900, layer: 0, bounds: popupBounds, onScreen: true, alpha: 0)
        let disjoint = WindowInfo(number: 54, pid: 900, layer: 0, bounds: Rect(x: 1350, y: 0, width: 50, height: 50), onScreen: true)
        XCTAssertEqual(assess(above: [menu, floating, invisible, disjoint]), .focused)
    }

    func testSecurityUIIsExempt() {
        XCTAssertEqual(assess(pid: 1, bundle: "com.apple.SecurityAgent"), .exempt)
        XCTAssertEqual(assess(pid: me, bundle: "io.github.thunderboltsid.ekagrachit"), .ownUI)
    }

    func testOffscreenOrMissing() {
        var minimized = focus
        minimized.onScreen = false
        XCTAssertEqual(assess(focus: minimized), .offscreen)
        XCTAssertEqual(assess(focus: .some(nil)), .offscreen)
    }
}
