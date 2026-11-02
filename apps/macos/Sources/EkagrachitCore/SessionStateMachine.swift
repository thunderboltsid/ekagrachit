import Foundation

/// The authoritative focus-session state machine (pure; no I/O).
///
///     idle ──start/restore/adopt──▶ preparing ──window+overlays──▶ active
///      ▲                              │  timeout/failure            │  ▲
///      │                              ▼                             ▼  │ recovered
///      └──────── (ack/timeout) ◀── ending ◀──── expiry/end ──── degraded
///
/// Permitted transitions (anything else is ignored):
///   idle      → preparing  (startRequested, restore, adoptRequested)
///   preparing → active     (focus window located natively AND overlays shown, extension connected)
///   preparing → ending     (prepare timeout, overlay failure, extension closed, user end, expiry)
///   active    → degraded   (extension disconnected, focus window missing)
///   degraded  → active     (extension connected AND focus window located)
///   degraded  → ending     (degraded timeout, user end, expiry, extension closed)
///   active    → ending     (expiry, user end, extension closed)
///   ending    → idle       (extension acknowledged, extension disconnected, or ending timeout)
///
/// The coordinator feeds events and executes the returned effects; it never
/// mutates `MachineState` itself. All timing comes from the `Instant` passed in.
public enum Phase: String, Codable, Sendable {
    case idle, preparing, active, degraded, ending
}

public enum DegradedReason: String, Codable, Sendable {
    case extensionDisconnected
    case focusWindowMissing
}

public enum EndReason: String, Codable, Sendable {
    case expired
    case userEnded
    case startFailed
    case recoveryFailed
    case extensionEnded
    case degradedTimeout
    case overlayFailed
}

public struct SessionContext: Equatable, Sendable {
    public var sid: String
    public var target: String
    public var deadline: Deadline
    public var startedAt: TimeInterval
    public var windowId: Int?
    public var tabId: Int?
    public var reportedBounds: Rect?
    public var nativeWindow: UInt32?
    public var overlaysUp: Bool = false
    public var degradedReason: DegradedReason?
    public var recovering: Bool = false

    public init(sid: String, target: String, deadline: Deadline, startedAt: TimeInterval, recovering: Bool = false) {
        self.sid = sid
        self.target = target
        self.deadline = deadline
        self.startedAt = startedAt
        self.recovering = recovering
    }
}

public struct MachineState: Equatable, Sendable {
    public var phase: Phase = .idle
    public var session: SessionContext?
    public var extensionConnected = false
    /// When the current phase was entered (for timeouts).
    public var phaseSince: Instant?
    public var lastEnd: EndReason?

    public init() {}
}

public enum MachineEvent: Equatable, Sendable {
    case startRequested(sid: String, target: String, duration: TimeInterval)
    case restore(PersistedSession)
    case adoptRequested(sid: String, target: String, remaining: TimeInterval)
    case extensionConnected
    case extensionDisconnected
    case windowReady(sid: String, windowId: Int, tabId: Int, bounds: Rect)
    case windowBounds(sid: String, windowId: Int, bounds: Rect)
    case windowLost(sid: String)
    case nativeWindowFound(sid: String, window: UInt32)
    case nativeWindowGone(sid: String)
    case overlaysShown(sid: String)
    case overlayFailed(sid: String)
    case extensionClosed(sid: String)
    case endRequested(EndReason)
    case tick
}

public enum MachineEffect: Equatable, Sendable {
    /// Push the desired session (derived from state) to the extension.
    case syncExtension
    /// Find the native window for the extension's popup (pid + bounds).
    case locateNativeWindow(windowId: Int, bounds: Rect)
    case stopWindowTracking
    case showOverlays
    case hideOverlays
    case persist
    case clearPersisted
    case sessionStarted
    case sessionEnded(EndReason)
    case refocus
}

public struct Transition: Equatable, Sendable {
    public var state: MachineState
    public var effects: [MachineEffect]
    /// Non-nil when a request was refused (state unchanged).
    public var rejection: String?
}

public struct MachineConfig: Sendable {
    public var prepareTimeout: TimeInterval = 25
    public var recoveryTimeout: TimeInterval = 30
    public var degradedTimeout: TimeInterval = 120
    public var endingTimeout: TimeInterval = 4
    public var minDuration: TimeInterval = 60
    public var maxDuration: TimeInterval = 8 * 3600

    public init() {}
}

public enum SessionStateMachine {
    public static func reduce(_ s: MachineState, _ event: MachineEvent, now: Instant, config: MachineConfig = MachineConfig()) -> Transition {
        var st = s
        var fx: [MachineEffect] = []

        func enter(_ phase: Phase) {
            st.phase = phase
            st.phaseSince = now
        }
        func end(_ reason: EndReason) {
            guard st.session != nil, st.phase != .ending, st.phase != .idle else { return }
            st.lastEnd = reason
            fx += [.hideOverlays, .stopWindowTracking, .clearPersisted]
            st.session?.overlaysUp = false
            if st.extensionConnected {
                enter(.ending) // wait briefly for the extension to close its window
                fx.append(.syncExtension)
            } else {
                enter(.idle)
                st.session = nil
            }
            fx.append(.sessionEnded(reason))
        }
        func finishEnding() {
            enter(.idle)
            st.session = nil
        }
        func reject(_ why: String) -> Transition { Transition(state: s, effects: [], rejection: why) }
        func matches(_ sid: String) -> Bool { st.session?.sid == sid && st.phase != .idle && st.phase != .ending }
        func maybeActivate() {
            guard let sess = st.session, sess.nativeWindow != nil, sess.overlaysUp, st.extensionConnected else { return }
            switch st.phase {
            case .preparing:
                enter(.active)
                st.session?.recovering = false
                fx += [.syncExtension, .sessionStarted, .refocus]
            case .degraded:
                enter(.active)
                st.session?.degradedReason = nil
                fx += [.syncExtension, .refocus]
            default:
                break
            }
        }
        func degrade(_ reason: DegradedReason) {
            if st.phase == .active {
                enter(.degraded)
                st.session?.degradedReason = reason
                fx.append(.syncExtension)
            } else if st.phase == .degraded {
                st.session?.degradedReason = reason
            }
        }

        switch event {
        case let .startRequested(sid, target, duration):
            guard st.phase == .idle else { return reject("A focus session is already running.") }
            guard st.extensionConnected else { return reject("The Ekagrachit Chrome extension is not connected. Is Chrome running with the extension installed?") }
            guard duration >= config.minDuration, duration <= config.maxDuration else { return reject("Duration must be between 1 minute and 8 hours.") }
            st.session = SessionContext(sid: sid, target: target, deadline: Deadline(start: now, duration: duration), startedAt: now.wall)
            st.lastEnd = nil
            enter(.preparing)
            fx += [.persist, .syncExtension]

        case let .restore(p):
            guard st.phase == .idle else { return reject("busy") }
            let remaining = p.deadline.remaining(at: now)
            guard remaining > 1 else {
                fx.append(.clearPersisted)
                break
            }
            st.session = SessionContext(sid: p.sid, target: p.target, deadline: p.deadline, startedAt: p.startedAt, recovering: true)
            enter(.preparing)
            fx.append(.syncExtension)

        case let .adoptRequested(sid, target, remaining):
            guard st.phase == .idle else { return reject("busy") }
            guard remaining > 1 else { return reject("expired") }
            let r = min(remaining, config.maxDuration)
            st.session = SessionContext(sid: sid, target: target, deadline: Deadline(start: now, duration: r), startedAt: now.wall)
            enter(.preparing)
            fx += [.persist, .syncExtension]

        case .extensionConnected:
            st.extensionConnected = true
            // Always sync: also tells a reconnecting extension to drop sessions we no longer have.
            fx.append(.syncExtension)

        case .extensionDisconnected:
            st.extensionConnected = false
            switch st.phase {
            case .active: degrade(.extensionDisconnected)
            case .ending: finishEnding()
            default: break
            }

        case let .windowReady(sid, windowId, tabId, bounds):
            guard matches(sid) else { break }
            if st.session?.windowId != windowId { st.session?.nativeWindow = nil }
            st.session?.windowId = windowId
            st.session?.tabId = tabId
            st.session?.reportedBounds = bounds
            fx.append(.locateNativeWindow(windowId: windowId, bounds: bounds))

        case let .windowBounds(sid, windowId, bounds):
            guard matches(sid), st.session?.windowId == windowId else { break }
            st.session?.reportedBounds = bounds
            if st.session?.nativeWindow == nil { fx.append(.locateNativeWindow(windowId: windowId, bounds: bounds)) }

        case let .windowLost(sid):
            guard matches(sid) else { break }
            st.session?.nativeWindow = nil
            st.session?.windowId = nil
            degrade(.focusWindowMissing)

        case let .nativeWindowFound(sid, window):
            guard matches(sid) else { break }
            st.session?.nativeWindow = window
            if st.session?.overlaysUp == false {
                fx.append(.showOverlays)
            }
            maybeActivate()

        case let .nativeWindowGone(sid):
            guard matches(sid) else { break }
            st.session?.nativeWindow = nil
            degrade(.focusWindowMissing)

        case let .overlaysShown(sid):
            guard matches(sid) else { break }
            st.session?.overlaysUp = true
            maybeActivate()

        case let .overlayFailed(sid):
            guard matches(sid) else { break }
            end(.overlayFailed)

        case let .extensionClosed(sid):
            if st.phase == .ending, st.session?.sid == sid {
                finishEnding()
            } else if matches(sid) {
                end(.extensionEnded)
            }

        case let .endRequested(reason):
            end(reason)

        case .tick:
            guard let sess = st.session else { break }
            let inPhase = st.phaseSince.map { now.seconds(since: $0) } ?? 0
            if st.phase == .ending {
                if inPhase >= config.endingTimeout { finishEnding() }
                break
            }
            if sess.deadline.remaining(at: now) <= 0 {
                end(.expired)
            } else if st.phase == .preparing, inPhase >= (sess.recovering ? config.recoveryTimeout : config.prepareTimeout) {
                end(sess.recovering ? .recoveryFailed : .startFailed)
            } else if st.phase == .degraded, inPhase >= config.degradedTimeout {
                end(.degradedTimeout)
            }
        }
        return Transition(state: st, effects: fx, rejection: nil)
    }

    /// What the extension should be doing right now.
    public static func desiredSession(_ s: MachineState, now: Instant) -> DesiredSession? {
        guard let sess = s.session else { return nil }
        let phase: String
        switch s.phase {
        case .preparing: phase = "preparing"
        case .active: phase = "active"
        case .degraded: phase = "degraded"
        case .idle, .ending: return nil
        }
        return DesiredSession(sid: sess.sid, target: sess.target, remainingMs: sess.deadline.remaining(at: now) * 1000, phase: phase)
    }
}
