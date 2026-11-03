import Foundation

/// How much focused time you've had, per day. Stored locally; holds only
/// dates and durations (never what you focused on).
public struct FocusLedger: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd" (in the user's calendar) -> focused seconds.
    public private(set) var seconds: [String: Int] = [:]
    /// "yyyy-MM-dd" -> number of sessions of at least `minimumSeconds`.
    public private(set) var sessions: [String: Int] = [:]

    public static let minimumSeconds = 60
    public static let keepDays = 90

    public init() {}

    /// Records a session's focused time against the day it ended.
    public mutating func record(seconds focused: TimeInterval, endedAt: Date, calendar: Calendar) {
        let s = Int(focused.rounded())
        guard s >= Self.minimumSeconds else { return }
        let key = Self.key(endedAt, calendar)
        seconds[key, default: 0] += s
        sessions[key, default: 0] += 1
        prune(now: endedAt, calendar: calendar)
    }

    public func seconds(on date: Date, calendar: Calendar) -> Int { seconds[Self.key(date, calendar)] ?? 0 }
    public func sessions(on date: Date, calendar: Calendar) -> Int { sessions[Self.key(date, calendar)] ?? 0 }

    /// Consecutive days with focused time, counting back from today (or from
    /// yesterday if nothing has been recorded today yet, so a streak isn't
    /// shown as broken in the morning).
    public func streak(on date: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: date)
        if seconds(on: day, calendar: calendar) == 0 {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var n = 0
        while seconds(on: day, calendar: calendar) > 0 {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    /// "25 min", "1 h", "1 h 05 min".
    public static func format(seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : String(format: "%d h %02d min", h, r)
    }

    /// One quiet line for the menu, or nil when there's nothing to say yet.
    public func summary(on date: Date, calendar: Calendar) -> String? {
        let today = seconds(on: date, calendar: calendar)
        let streak = streak(on: date, calendar: calendar)
        var parts: [String] = []
        if today > 0 { parts.append("Today: \(Self.format(seconds: today)) focused") }
        if streak >= 2 { parts.append("\(streak)-day streak") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private mutating func prune(now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let min = Self.key(cutoff, calendar)
        seconds = seconds.filter { $0.key >= min }
        sessions = sessions.filter { $0.key >= min }
    }
}
