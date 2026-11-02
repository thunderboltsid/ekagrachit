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

final class FocusLossDebouncerTests: XCTestCase {
    func at(_ s: Double) -> Instant { Instant(wall: 1000 + s, mono: UInt64((1000 + s) * 1e9), bootID: "b") }

    func testOtherAppIsAlwaysBouncedBack() {
        var d = FocusLossDebouncer()
        for t in stride(from: 0.0, through: 10, by: 0.5) {
            XCTAssertEqual(d.next(.lost(reason: "x"), frontmostIsBrowser: false, now: at(t)), .closeHoleAndRefocus)
        }
    }

    func testStuckWindowAboveFocusDoesNotLockUserOut() {
        var d = FocusLossDebouncer(stuckAfter: 2.5)
        XCTAssertEqual(d.next(.lost(reason: "x"), frontmostIsBrowser: true, now: at(0)), .closeHoleAndRefocus)
        XCTAssertEqual(d.next(.lost(reason: "x"), frontmostIsBrowser: true, now: at(2)), .closeHoleAndRefocus)
        XCTAssertEqual(d.next(.lost(reason: "x"), frontmostIsBrowser: true, now: at(2.6)), .openHole)
        XCTAssertEqual(d.next(.focused, frontmostIsBrowser: true, now: at(3)), .openHole)
        // Resets: a new loss is shielded again.
        XCTAssertEqual(d.next(.lost(reason: "x"), frontmostIsBrowser: true, now: at(4)), .closeHoleAndRefocus)
    }

    func testOtherStates() {
        var d = FocusLossDebouncer()
        XCTAssertEqual(d.next(.exempt, frontmostIsBrowser: false, now: at(0)), .standAside)
        XCTAssertEqual(d.next(.offscreen, frontmostIsBrowser: true, now: at(0)), .coverAllAndRefocus)
        XCTAssertEqual(d.next(.ownUI, frontmostIsBrowser: false, now: at(0)), .openHole)
    }
}

final class IntruderPatchTests: XCTestCase {
    let focus = Rect(x: 120, y: 140, width: 900, height: 600)

    func testDockOverlappingTheFocusWindowIsPatched() {
        let dock = WindowInfo(number: 9, pid: 300, layer: 20, bounds: Rect(x: 100, y: 700, width: 900, height: 68), onScreen: true)
        XCTAssertEqual(FocusPolicy.intruderPatches(focus: focus, above: [dock], browserPid: 500, ownPid: 42, overlayLayer: 26),
                       [Rect(x: 120, y: 700, width: 880, height: 40)])
    }

    func testFloatingPanelsOfOtherAppsArePatchedButNotOwnOrBrowserOrSystemOrAboveUs() {
        let floating = WindowInfo(number: 1, pid: 900, layer: 3, bounds: Rect(x: 200, y: 200, width: 100, height: 100), onScreen: true)
        let chromeBubble = WindowInfo(number: 2, pid: 500, layer: 3, bounds: Rect(x: 200, y: 200, width: 100, height: 100), onScreen: true)
        let mine = WindowInfo(number: 3, pid: 42, layer: 27, bounds: focus, onScreen: true)
        let normal = WindowInfo(number: 4, pid: 900, layer: 0, bounds: focus, onScreen: true)
        let menu = WindowInfo(number: 5, pid: 900, layer: 101, bounds: focus, onScreen: true)
        let security = WindowInfo(number: 6, pid: 77, layer: 8, bounds: focus, onScreen: true)
        let invisible = WindowInfo(number: 7, pid: 900, layer: 3, bounds: focus, onScreen: true, alpha: 0)
        let outside = WindowInfo(number: 8, pid: 900, layer: 3, bounds: Rect(x: 0, y: 0, width: 50, height: 50), onScreen: true)
        let patches = FocusPolicy.intruderPatches(focus: focus, above: [floating, chromeBubble, mine, normal, menu, security, invisible, outside],
                                                  browserPid: 500, ownPid: 42, overlayLayer: 26, exemptPids: [77])
        XCTAssertEqual(patches, [Rect(x: 200, y: 200, width: 100, height: 100)])
    }
}
