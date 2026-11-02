import XCTest
@testable import EkagrachitCore

final class DeadlineTests: XCTestCase {
    let start = Instant(wall: 1_000_000, mono: 5_000_000_000_000, bootID: "boot-1")

    func advance(_ i: Instant, wall: TimeInterval, mono: TimeInterval, boot: String? = nil) -> Instant {
        Instant(wall: i.wall + wall, mono: UInt64(Int64(i.mono) + Int64(mono * 1e9)), bootID: boot ?? i.bootID)
    }

    func testCountsDownWithRealTime() {
        let d = Deadline(start: start, duration: 45 * 60)
        XCTAssertEqual(d.remaining(at: start), 2700, accuracy: 0.001)
        XCTAssertEqual(d.remaining(at: advance(start, wall: 600, mono: 600)), 2100, accuracy: 0.001)
    }

    func testSleepCountsAsElapsedTime() {
        // Mac sleeps for 50 minutes: both clocks advance (CLOCK_MONOTONIC includes sleep on Darwin).
        let d = Deadline(start: start, duration: 45 * 60)
        XCTAssertEqual(d.remaining(at: advance(start, wall: 3000, mono: 3000)), 0)
    }

    func testWallClockSetBackwardsCannotExtendSession() {
        let d = Deadline(start: start, duration: 25 * 60)
        // 20 minutes pass, then the user sets the clock back by 1 hour.
        let now = advance(start, wall: 1200 - 3600, mono: 1200)
        XCTAssertEqual(d.remaining(at: now), 300, accuracy: 0.001)
    }

    func testWallClockJumpForwardEndsEarly() {
        let d = Deadline(start: start, duration: 25 * 60)
        XCTAssertEqual(d.remaining(at: advance(start, wall: 7200, mono: 60)), 0)
    }

    func testAfterRebootOnlyWallClockApplies() {
        let d = Deadline(start: start, duration: 25 * 60)
        let rebooted = Instant(wall: start.wall + 600, mono: 10, bootID: "boot-2")
        XCTAssertEqual(d.remaining(at: rebooted), 900, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        let d = Deadline(start: start, duration: 60)
        let back = try JSONDecoder().decode(Deadline.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(d, back)
    }

    func testSystemClockIsMonotonic() {
        let a = SystemClock.shared.now()
        let b = SystemClock.shared.now()
        XCTAssertGreaterThanOrEqual(b.mono, a.mono)
        XCTAssertEqual(a.bootID, b.bootID)
        XCTAssertNotEqual(a.bootID, "unknown")
    }
}
