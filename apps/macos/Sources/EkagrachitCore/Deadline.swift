import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A point in time as seen by three clocks.
///
/// - `wall`: seconds since 1970 (can jump: NTP, manual clock changes).
/// - `mono`: nanoseconds from a monotonic clock that keeps counting while the
///   machine sleeps (Darwin `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`). Never
///   jumps, but only comparable within one boot.
/// - `bootID`: identifies the boot in which `mono` is meaningful.
public struct Instant: Equatable, Sendable {
    public var wall: TimeInterval
    public var mono: UInt64
    public var bootID: String

    public init(wall: TimeInterval, mono: UInt64, bootID: String) {
        self.wall = wall
        self.mono = mono
        self.bootID = bootID
    }

    /// Seconds elapsed since `earlier` according to the monotonic clock (0 across boots).
    public func seconds(since earlier: Instant) -> TimeInterval {
        guard bootID == earlier.bootID, mono >= earlier.mono else { return 0 }
        return TimeInterval(mono - earlier.mono) / 1_000_000_000
    }
}

/// Absolute session deadline.
///
/// Semantics (documented in docs/architecture.md, "Time"):
///  - Duration is real elapsed time. Sleep counts: a 45-minute session started
///    at 10:00 is over at 10:45 even if the Mac slept in between.
///  - The session ends at the EARLIER of the wall-clock deadline and the
///    monotonic deadline. Moving the clock backwards (or a suspended process)
///    can therefore never extend a session; moving it forwards may end it early,
///    which is the safe direction.
///  - After a reboot the monotonic deadline is meaningless and only the
///    wall-clock deadline applies.
public struct Deadline: Codable, Equatable, Sendable {
    public var wall: TimeInterval
    public var mono: UInt64
    public var bootID: String

    public init(start: Instant, duration: TimeInterval) {
        let d = max(0, duration)
        wall = start.wall + d
        mono = start.mono &+ UInt64(d * 1_000_000_000)
        bootID = start.bootID
    }

    public func remaining(at now: Instant) -> TimeInterval {
        let wallRemaining = wall - now.wall
        guard now.bootID == bootID else { return max(0, wallRemaining) }
        let monoRemaining = mono >= now.mono ? TimeInterval(mono - now.mono) / 1_000_000_000 : -TimeInterval(now.mono - mono) / 1_000_000_000
        return max(0, min(wallRemaining, monoRemaining))
    }
}

/// Source of `Instant`s. Injected so the state machine is testable.
public protocol Clock: Sendable {
    func now() -> Instant
}

public struct SystemClock: Clock {
    public static let shared = SystemClock()
    private let boot: String

    public init() {
        boot = SystemClock.readBootID()
    }

    public func now() -> Instant {
        Instant(wall: Date().timeIntervalSince1970, mono: SystemClock.monotonicNanos(), bootID: boot)
    }

    static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        #if canImport(Darwin)
        // On Darwin CLOCK_MONOTONIC continues to advance during sleep.
        clock_gettime(CLOCK_MONOTONIC, &ts)
        #else
        clock_gettime(CLOCK_BOOTTIME, &ts)
        #endif
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    static func readBootID() -> String {
        #if canImport(Darwin)
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &tv, &size, nil, 0) == 0 {
            return "\(tv.tv_sec).\(tv.tv_usec)"
        }
        return "unknown"
        #else
        if let s = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "unknown"
        #endif
    }
}
