import XCTest
@testable import EkagrachitCore

final class NativeTargetStateTests: XCTestCase {
    var clock = Instant(wall: 1_700_000_000, mono: 1_000_000_000_000, bootID: "b")
    let sid = "nnnnnnnnnnnnnnnn"
    let word = NativeWindowTarget(bundleID: "com.microsoft.Word", appName: "Microsoft Word", title: "Q3 plan.docx", pid: 4242, windowNumber: 77)

    @discardableResult
    func step(_ s: inout MachineState, _ e: MachineEvent) -> Transition {
        let t = SessionStateMachine.reduce(s, e, now: clock)
        s = t.state
        return t
    }

    func tick(_ seconds: TimeInterval) {
        clock = Instant(wall: clock.wall + seconds, mono: clock.mono + UInt64(seconds * 1e9), bootID: clock.bootID)
    }

    func testNativeSessionNeedsNoExtension() {
        var s = MachineState() // extension never connected
        let t = step(&s, .startAppRequested(sid: sid, app: word, duration: 1500))
        XCTAssertNil(t.rejection)
        XCTAssertEqual(t.effects, [.persist, .locateAppWindow(word)])
        XCTAssertEqual(s.session?.target, "Q3 plan.docx — Microsoft Word")
        XCTAssertNil(SessionStateMachine.desiredSession(s, now: clock), "nothing for the browser to do")
        step(&s, .nativeWindowFound(sid: sid, window: 77))
        let active = step(&s, .overlaysShown(sid: sid))
        XCTAssertEqual(s.phase, .active)
        XCTAssertTrue(active.effects.contains(.sessionStarted))
    }

    func testExtensionComingAndGoingDoesNotAffectNativeSession() {
        var s = MachineState()
        step(&s, .extensionConnected)
        step(&s, .startAppRequested(sid: sid, app: word, duration: 1500))
        step(&s, .nativeWindowFound(sid: sid, window: 77))
        step(&s, .overlaysShown(sid: sid))
        step(&s, .extensionDisconnected)
        XCTAssertEqual(s.phase, .active)
    }

    func testNativeEndGoesStraightToIdleEvenWithExtensionConnected() {
        var s = MachineState()
        step(&s, .extensionConnected)
        step(&s, .startAppRequested(sid: sid, app: word, duration: 1500))
        step(&s, .nativeWindowFound(sid: sid, window: 77))
        step(&s, .overlaysShown(sid: sid))
        let t = step(&s, .endRequested(.userEnded))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(t.effects.contains(.hideOverlays))
    }

    func testClosedWindowIsSearchedForAgainThenTimesOut() {
        var s = MachineState()
        step(&s, .startAppRequested(sid: sid, app: word, duration: 1500))
        step(&s, .nativeWindowFound(sid: sid, window: 77))
        step(&s, .overlaysShown(sid: sid))
        let gone = step(&s, .nativeWindowGone(sid: sid))
        XCTAssertEqual(s.phase, .degraded)
        XCTAssertTrue(gone.effects.contains(.locateAppWindow(word)))
        step(&s, .nativeWindowFound(sid: sid, window: 91)) // e.g. Word reopened the document
        XCTAssertEqual(s.phase, .active)
        step(&s, .nativeWindowGone(sid: sid))
        tick(121)
        step(&s, .tick)
        XCTAssertEqual(s.lastEnd, .degradedTimeout)
    }

    func testRestoreNativeSession() throws {
        let p = PersistedSession(sid: sid, target: word.displayName, startedAt: clock.wall, deadline: Deadline(start: clock, duration: 600), app: word)
        let roundTrip = try JSONDecoder().decode(PersistedSession.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(roundTrip.app, word)
        var s = MachineState()
        let t = step(&s, .restore(roundTrip))
        XCTAssertEqual(t.effects, [.locateAppWindow(word)])
        XCTAssertEqual(s.session?.app, word)
    }

    func testOlderSessionFilesWithoutAppStillDecode() throws {
        let json = #"{"version":1,"sid":"0123456789abcdef","target":"https://x","startedAt":1,"deadline":{"wall":2,"mono":3,"bootID":"b"}}"#
        let p = try JSONDecoder().decode(PersistedSession.self, from: Data(json.utf8))
        XCTAssertNil(p.app)
    }
}

final class WindowCandidateTests: XCTestCase {
    func c(_ n: UInt32, _ bundle: String, _ title: String, z: Int, w: Double = 800, h: Double = 600, pid: Int32 = 10) -> WindowCandidate {
        WindowCandidate(number: n, pid: pid, bundleID: bundle, appName: bundle, title: title, bounds: Rect(x: 0, y: 0, width: w, height: h), zIndex: z)
    }

    func testRankingFiltersAndOrders() {
        let all = [
            c(1, "com.todesktop.230313mzl4w4u92", "ekagrachit — Cursor", z: 2),
            c(2, "com.google.Chrome", "Docs", z: 0),
            c(3, "io.github.thunderboltsid.ekagrachit", "Settings", z: 1),
            c(4, "com.apple.finder", "Downloads", z: 3),
            c(5, "com.googlecode.iterm2", "zsh", z: 4),
            c(6, "com.apple.TextEdit", "tiny", z: 5, w: 100, h: 50),
            c(7, "com.microsoft.Word", "Q3 plan.docx", z: 6),
        ]
        let ranked = WindowCandidates.rank(all, ownBundleID: "io.github.thunderboltsid.ekagrachit")
        XCTAssertEqual(ranked.map(\.number), [1, 5, 7])
    }

    func testRelocate() {
        let t = NativeWindowTarget(bundleID: "com.apple.Pages", appName: "Pages", title: "Essay", pid: 10, windowNumber: 50)
        XCTAssertEqual(WindowCandidates.relocate(t, in: [c(50, "com.apple.Pages", "Essay", z: 0), c(51, "com.apple.Pages", "Other", z: 1)])?.number, 50)
        // Window number changed (app relaunched, new pid): found by title.
        XCTAssertEqual(WindowCandidates.relocate(t, in: [c(60, "com.apple.Pages", "Other", z: 0, pid: 11), c(61, "com.apple.Pages", "Essay", z: 1, pid: 11)])?.number, 61)
        // Title changed but it's the app's only window.
        XCTAssertEqual(WindowCandidates.relocate(t, in: [c(70, "com.apple.Pages", "Essay (edited)", z: 0, pid: 11)])?.number, 70)
        // Ambiguous: no guess.
        XCTAssertNil(WindowCandidates.relocate(t, in: [c(80, "com.apple.Pages", "A", z: 0, pid: 11), c(81, "com.apple.Pages", "B", z: 1, pid: 11)]))
    }
}
