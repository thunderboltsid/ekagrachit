import XCTest
@testable import EkagrachitCore

/// Test D (lifecycle) at the state-machine level.
final class StateMachineTests: XCTestCase {
    var clock = Instant(wall: 1_700_000_000, mono: 1_000_000_000_000, bootID: "b")
    let sid = "aaaaaaaaaaaaaaaa"
    let bounds = Rect(x: 0, y: 25, width: 1200, height: 800)

    func tick(_ seconds: TimeInterval) {
        clock = Instant(wall: clock.wall + seconds, mono: clock.mono + UInt64(seconds * 1e9), bootID: clock.bootID)
    }

    @discardableResult
    func step(_ s: inout MachineState, _ e: MachineEvent) -> Transition {
        let t = SessionStateMachine.reduce(s, e, now: clock)
        s = t.state
        return t
    }

    func connectedIdle() -> MachineState {
        var s = MachineState()
        step(&s, .extensionConnected)
        return s
    }

    func activeSession(duration: TimeInterval = 1500) -> MachineState {
        var s = connectedIdle()
        step(&s, .startRequested(sid: sid, target: "https://docs.google.com/document/d/A/edit", duration: duration))
        step(&s, .windowReady(sid: sid, windowId: 1, tabId: 2, bounds: bounds))
        step(&s, .nativeWindowFound(sid: sid, window: 99))
        step(&s, .overlaysShown(sid: sid))
        return s
    }

    func testHappyPathRequiresEveryPrerequisite() {
        var s = connectedIdle()
        var t = step(&s, .startRequested(sid: sid, target: "https://x.example/", duration: 1500))
        XCTAssertEqual(s.phase, .preparing)
        XCTAssertEqual(t.effects, [.persist, .syncExtension])
        t = step(&s, .windowReady(sid: sid, windowId: 1, tabId: 2, bounds: bounds))
        XCTAssertEqual(t.effects, [.locateNativeWindow(windowId: 1, bounds: bounds)])
        XCTAssertEqual(s.phase, .preparing)
        t = step(&s, .nativeWindowFound(sid: sid, window: 99))
        XCTAssertEqual(t.effects, [.showOverlays])
        XCTAssertEqual(s.phase, .preparing, "not active until overlays are established")
        t = step(&s, .overlaysShown(sid: sid))
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(t.effects, [.syncExtension, .sessionStarted, .refocus])
        XCTAssertEqual(SessionStateMachine.desiredSession(s, now: clock)?.phase, "active")
    }

    func testStartRejectedWithoutExtensionOrWhileBusy() {
        var s = MachineState()
        XCTAssertNotNil(step(&s, .startRequested(sid: sid, target: "https://x", duration: 1500)).rejection)
        XCTAssertEqual(s.phase, .idle)
        s = activeSession()
        let t = step(&s, .startRequested(sid: "bbbbbbbbbbbbbbbb", target: "https://y", duration: 1500))
        XCTAssertNotNil(t.rejection)
        XCTAssertEqual(s.session?.sid, sid)
    }

    func testDurationBounds() {
        var s = connectedIdle()
        XCTAssertNotNil(step(&s, .startRequested(sid: sid, target: "https://x", duration: 10)).rejection)
        XCTAssertNotNil(step(&s, .startRequested(sid: sid, target: "https://x", duration: 9 * 3600)).rejection)
    }

    func testStaleSessionMessagesAreIgnored() {
        var s = activeSession()
        let before = s
        for e: MachineEvent in [
            .windowLost(sid: "zzzzzzzzzzzzzzzz"),
            .nativeWindowGone(sid: "zzzzzzzzzzzzzzzz"),
            .extensionClosed(sid: "zzzzzzzzzzzzzzzz"),
            .windowReady(sid: "zzzzzzzzzzzzzzzz", windowId: 7, tabId: 8, bounds: bounds),
            .overlayFailed(sid: "zzzzzzzzzzzzzzzz"),
        ] {
            let t = step(&s, e)
            XCTAssertEqual(t.effects, [])
        }
        XCTAssertEqual(s, before)
    }

    func testExpiryEndsSessionAndWaitsForExtension() {
        var s = activeSession(duration: 120)
        tick(119)
        step(&s, .tick)
        XCTAssertEqual(s.phase, .active)
        tick(1)
        let t = step(&s, .tick)
        XCTAssertEqual(s.phase, .ending)
        XCTAssertEqual(s.lastEnd, .expired)
        XCTAssertEqual(t.effects, [.hideOverlays, .stopWindowTracking, .clearPersisted, .syncExtension, .sessionEnded(.expired)])
        XCTAssertNil(SessionStateMachine.desiredSession(s, now: clock), "extension is told the session is over")
        step(&s, .extensionClosed(sid: sid))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertNil(s.session)
    }

    func testEndingTimesOutIfExtensionNeverAcknowledges() {
        var s = activeSession()
        step(&s, .endRequested(.userEnded))
        XCTAssertEqual(s.phase, .ending)
        tick(5)
        step(&s, .tick)
        XCTAssertEqual(s.phase, .idle)
    }

    func testRepeatedEndRequestsAreIdempotent() {
        var s = activeSession()
        let first = step(&s, .endRequested(.userEnded))
        XCTAssertFalse(first.effects.isEmpty)
        for _ in 0..<3 {
            XCTAssertEqual(step(&s, .endRequested(.userEnded)).effects, [])
            XCTAssertEqual(step(&s, .endRequested(.expired)).effects, [])
        }
        XCTAssertEqual(s.lastEnd, .userEnded)
    }

    func testEndWhileExtensionDisconnectedGoesStraightToIdle() {
        var s = activeSession()
        step(&s, .extensionDisconnected)
        XCTAssertEqual(s.phase, .degraded)
        let t = step(&s, .endRequested(.userEnded))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(t.effects.contains(.hideOverlays))
    }

    func testDegradedAndRecoveredAfterExtensionReconnects() {
        var s = activeSession()
        step(&s, .extensionDisconnected)
        XCTAssertEqual(s.phase, .degraded)
        XCTAssertEqual(s.session?.degradedReason, .extensionDisconnected)
        step(&s, .extensionConnected)
        XCTAssertEqual(s.phase, .degraded, "stays degraded until the window is re-verified")
        step(&s, .windowReady(sid: sid, windowId: 1, tabId: 2, bounds: bounds))
        let t = step(&s, .nativeWindowFound(sid: sid, window: 99))
        XCTAssertEqual(s.phase, .active)
        XCTAssertTrue(t.effects.contains(.syncExtension))
    }

    func testFocusWindowClosedAndRecreated() {
        var s = activeSession()
        step(&s, .windowLost(sid: sid))
        XCTAssertEqual(s.phase, .degraded)
        XCTAssertNil(s.session?.nativeWindow)
        step(&s, .windowReady(sid: sid, windowId: 5, tabId: 6, bounds: bounds))
        step(&s, .nativeWindowFound(sid: sid, window: 120))
        XCTAssertEqual(s.phase, .active)
        XCTAssertEqual(s.session?.windowId, 5)
    }

    func testDegradedTimeoutEndsSessionRatherThanTrappingTheUser() {
        var s = activeSession()
        step(&s, .nativeWindowGone(sid: sid))
        tick(119)
        step(&s, .tick)
        XCTAssertEqual(s.phase, .degraded)
        tick(2)
        step(&s, .tick)
        XCTAssertEqual(s.phase, .ending)
        XCTAssertEqual(s.lastEnd, .degradedTimeout)
    }

    func testPrepareTimeoutCleansUp() {
        var s = connectedIdle()
        step(&s, .startRequested(sid: sid, target: "https://x", duration: 1500))
        tick(26)
        let t = step(&s, .tick)
        XCTAssertEqual(s.lastEnd, .startFailed)
        XCTAssertTrue(t.effects.contains(.hideOverlays))
        XCTAssertTrue(t.effects.contains(.clearPersisted))
    }

    func testPartialActivationOverlayFailure() {
        var s = connectedIdle()
        step(&s, .startRequested(sid: sid, target: "https://x", duration: 1500))
        step(&s, .windowReady(sid: sid, windowId: 1, tabId: 2, bounds: bounds))
        step(&s, .nativeWindowFound(sid: sid, window: 99))
        step(&s, .overlayFailed(sid: sid))
        XCTAssertEqual(s.lastEnd, .overlayFailed)
        XCTAssertNotEqual(s.phase, .active)
    }

    func testExtensionEndedSession() {
        var s = activeSession()
        step(&s, .extensionClosed(sid: sid))
        XCTAssertEqual(s.lastEnd, .extensionEnded)
    }

    func testRestoreAfterAppRestart() {
        let persisted = PersistedSession(sid: sid, target: "https://x", startedAt: clock.wall, deadline: Deadline(start: clock, duration: 600))
        tick(100)
        var s = MachineState()
        var t = step(&s, .restore(persisted))
        XCTAssertEqual(s.phase, .preparing)
        XCTAssertTrue(s.session!.recovering)
        XCTAssertEqual(SessionStateMachine.desiredSession(s, now: clock)!.remainingMs, 500_000, accuracy: 1)
        step(&s, .extensionConnected)
        step(&s, .windowReady(sid: sid, windowId: 1, tabId: 2, bounds: bounds))
        step(&s, .nativeWindowFound(sid: sid, window: 1))
        t = step(&s, .overlaysShown(sid: sid))
        XCTAssertEqual(s.phase, .active)
        XCTAssertTrue(t.effects.contains(.sessionStarted))
    }

    func testRestoreOfExpiredSessionClearsIt() {
        let persisted = PersistedSession(sid: sid, target: "https://x", startedAt: clock.wall, deadline: Deadline(start: clock, duration: 60))
        tick(3600)
        var s = MachineState()
        let t = step(&s, .restore(persisted))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(t.effects, [.clearPersisted])
    }

    func testRecoveryFailureCleansUp() {
        let persisted = PersistedSession(sid: sid, target: "https://x", startedAt: clock.wall, deadline: Deadline(start: clock, duration: 600))
        var s = MachineState()
        step(&s, .restore(persisted))
        tick(31)
        step(&s, .tick)
        XCTAssertEqual(s.lastEnd, .recoveryFailed)
        XCTAssertNil(s.session)
    }

    func testAdoptStandaloneExtensionSession() {
        var s = connectedIdle()
        step(&s, .adoptRequested(sid: sid, target: "https://x", remaining: 300))
        XCTAssertEqual(s.phase, .preparing)
        XCTAssertEqual(s.session?.sid, sid)
        XCTAssertEqual(SessionStateMachine.desiredSession(s, now: clock)!.remainingMs, 300_000, accuracy: 1)
    }

    func testSleepPastDeadlineEndsOnFirstTickAfterWake() {
        var s = activeSession(duration: 25 * 60)
        tick(3 * 3600) // asleep; no ticks delivered
        step(&s, .tick)
        XCTAssertEqual(s.lastEnd, .expired)
    }
}
