import Foundation
import XCTest
@testable import EkagrachitCore

final class FocusLedgerTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }()
    func day(_ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h))! }

    func testRecordsPerDayAndIgnoresTinySessions() {
        var l = FocusLedger()
        l.record(seconds: 25 * 60, endedAt: day(10), calendar: cal)
        l.record(seconds: 50 * 60, endedAt: day(10, 18), calendar: cal)
        l.record(seconds: 30, endedAt: day(10), calendar: cal)
        XCTAssertEqual(l.seconds(on: day(10, 8), calendar: cal), 75 * 60)
        XCTAssertEqual(l.sessions(on: day(10), calendar: cal), 2)
        XCTAssertEqual(l.seconds(on: day(11), calendar: cal), 0)
    }

    func testStreakCountsBackAndForgivesAnEmptyMorning() {
        var l = FocusLedger()
        for d in [7, 8, 9, 10] { l.record(seconds: 1500, endedAt: day(d), calendar: cal) }
        XCTAssertEqual(l.streak(on: day(10), calendar: cal), 4)
        XCTAssertEqual(l.streak(on: day(11, 8), calendar: cal), 4, "nothing yet today: yesterday's streak stands")
        XCTAssertEqual(l.streak(on: day(12), calendar: cal), 0)
        // A gap breaks it.
        l.record(seconds: 1500, endedAt: day(12), calendar: cal)
        XCTAssertEqual(l.streak(on: day(12), calendar: cal), 1)
    }

    func testSummaryAndFormat() {
        var l = FocusLedger()
        XCTAssertNil(l.summary(on: day(10), calendar: cal))
        l.record(seconds: 3900, endedAt: day(9), calendar: cal)
        XCTAssertNil(l.summary(on: day(10), calendar: cal), "a one-day streak and nothing today says nothing")
        l.record(seconds: 1500, endedAt: day(10), calendar: cal)
        XCTAssertEqual(l.summary(on: day(10), calendar: cal), "Today: 25 min focused · 2-day streak")
        XCTAssertEqual(FocusLedger.format(seconds: 3600), "1 h")
        XCTAssertEqual(FocusLedger.format(seconds: 3900), "1 h 05 min")
    }

    func testPrunesOldDaysAndRoundTrips() throws {
        var l = FocusLedger()
        l.record(seconds: 1500, endedAt: cal.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 12))!, calendar: cal)
        l.record(seconds: 1500, endedAt: day(10), calendar: cal)
        XCTAssertEqual(l.seconds.count, 1)
        let back = try JSONDecoder().decode(FocusLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}
