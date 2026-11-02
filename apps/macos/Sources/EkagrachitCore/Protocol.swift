import Foundation

/// Bridge protocol v1 (see docs/protocol.md). Mirrors
/// extensions/chrome/src/shared/protocol.ts.
public enum BridgeProtocol {
    public static let version = 1
    public static let hostName = "io.github.thunderboltsid.ekagrachit"
    public static let maxTargetLength = 4096

    public static func isValidSid(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public static func newSid() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public struct StandaloneSession: Equatable, Sendable {
    public var sid: String
    public var target: String
    public var remainingMs: Double
}

/// Messages received by the app (from the extension, relayed by the host, or from the host itself).
public enum AppInbound: Equatable, Sendable {
    case hostHello(browserPid: Int32, hostVersion: String)
    case hello(protocolVersion: Int, extVersion: String, extensionId: String, standalone: StandaloneSession?)
    case startRequest(cid: String, target: String, durationMinutes: Int)
    case endRequest(sid: String)
    case windowReady(sid: String, windowId: Int, tabId: Int, bounds: Rect, state: String)
    case windowBounds(sid: String, windowId: Int, bounds: Rect, state: String)
    case windowLost(sid: String)
    case violation(sid: String, kind: String)
    case sessionClosed(sid: String, reason: String)
    case error(sid: String?, code: String, message: String)

    /// Strict parser: anything malformed, oversized or unknown yields nil.
    public static func parse(_ data: Data) -> AppInbound? {
        guard data.count <= Framing.maxMessageSize,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        let sid = (obj["sid"] as? String).flatMap { BridgeProtocol.isValidSid($0) ? $0 : nil }
        switch type {
        case "host_hello":
            guard let pid = int(obj["browserPid"]), pid > 0, pid <= Int(Int32.max) else { return nil }
            return .hostHello(browserPid: Int32(pid), hostVersion: str(obj["hostVersion"], 32) ?? "unknown")
        case "hello":
            guard let p = int(obj["protocol"]) else { return nil }
            var standalone: StandaloneSession?
            if let s = obj["standalone"] as? [String: Any] {
                guard let ssid = s["sid"] as? String, BridgeProtocol.isValidSid(ssid),
                      let target = str(s["target"], BridgeProtocol.maxTargetLength),
                      let rem = (s["remainingMs"] as? NSNumber)?.doubleValue, rem.isFinite, rem >= 0, rem <= 86_400_000
                else { return nil }
                standalone = StandaloneSession(sid: ssid, target: target, remainingMs: rem)
            }
            return .hello(protocolVersion: p, extVersion: str(obj["extVersion"], 32) ?? "unknown",
                          extensionId: str(obj["extensionId"], 64) ?? "", standalone: standalone)
        case "start_request":
            guard let cid = str(obj["cid"], 64), let target = str(obj["target"], BridgeProtocol.maxTargetLength),
                  let minutes = int(obj["durationMinutes"]) else { return nil }
            return .startRequest(cid: cid, target: target, durationMinutes: minutes)
        case "end_request":
            guard let sid else { return nil }
            return .endRequest(sid: sid)
        case "window_ready", "window_bounds":
            guard let sid, let windowId = int(obj["windowId"]), let bounds = rect(obj["bounds"]) else { return nil }
            let state = str(obj["state"], 32) ?? "normal"
            if type == "window_bounds" { return .windowBounds(sid: sid, windowId: windowId, bounds: bounds, state: state) }
            guard let tabId = int(obj["tabId"]) else { return nil }
            return .windowReady(sid: sid, windowId: windowId, tabId: tabId, bounds: bounds, state: state)
        case "window_lost":
            guard let sid else { return nil }
            return .windowLost(sid: sid)
        case "violation":
            guard let sid, let kind = str(obj["kind"], 64) else { return nil }
            return .violation(sid: sid, kind: kind)
        case "session_closed":
            guard let sid else { return nil }
            return .sessionClosed(sid: sid, reason: str(obj["reason"], 64) ?? "unknown")
        case "error":
            guard let code = str(obj["code"], 64) else { return nil }
            return .error(sid: sid, code: code, message: str(obj["message"], 512) ?? "")
        default:
            return nil
        }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            #if canImport(Darwin)
            // Reject booleans masquerading as numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            #endif
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
            return Int(d)
        }
        return nil
    }

    private static func str(_ v: Any?, _ max: Int) -> String? {
        guard let s = v as? String, s.count <= max else { return nil }
        return s
    }

    private static func rect(_ v: Any?) -> Rect? {
        guard let o = v as? [String: Any],
              let l = (o["left"] as? NSNumber)?.doubleValue, let t = (o["top"] as? NSNumber)?.doubleValue,
              let w = (o["width"] as? NSNumber)?.doubleValue, let h = (o["height"] as? NSNumber)?.doubleValue,
              [l, t, w, h].allSatisfy({ $0.isFinite && abs($0) < 100_000 }), w > 0, h > 0
        else { return nil }
        return Rect(x: l, y: t, width: w, height: h)
    }
}

/// The desired session pushed to the extension.
public struct DesiredSession: Equatable, Sendable {
    public var sid: String
    public var target: String
    public var remainingMs: Double
    public var phase: String
}

/// Messages sent by the app to the extension.
public enum AppOutbound: Equatable, Sendable {
    case helloAck(appVersion: String, epoch: String)
    case sync(epoch: String, seq: Int, session: DesiredSession?)
    case focus(sid: String)
    case startResult(cid: String, ok: Bool, error: String?)
    case error(code: String, message: String)

    public var json: [String: Any] {
        switch self {
        case let .helloAck(appVersion, epoch):
            return ["v": 1, "type": "hello_ack", "protocol": BridgeProtocol.version, "appVersion": appVersion, "epoch": epoch]
        case let .sync(epoch, seq, session):
            var m: [String: Any] = ["v": 1, "type": "sync", "epoch": epoch, "seq": seq]
            if let s = session {
                m["session"] = ["sid": s.sid, "target": s.target, "remainingMs": max(0, s.remainingMs.rounded()), "phase": s.phase]
            } else {
                m["session"] = NSNull()
            }
            return m
        case let .focus(sid):
            return ["v": 1, "type": "focus", "sid": sid]
        case let .startResult(cid, ok, error):
            var m: [String: Any] = ["v": 1, "type": "start_result", "cid": cid, "ok": ok]
            if let error { m["error"] = error }
            return m
        case let .error(code, message):
            return ["v": 1, "type": "error", "code": code, "message": message]
        }
    }

    public func encoded() -> Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// Message the host itself sends to the extension.
public enum HostMessages {
    public static func status(appConnected: Bool, hostVersion: String) -> Data {
        let m: [String: Any] = ["v": 1, "type": "host_status", "appConnected": appConnected, "hostVersion": hostVersion]
        return (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data()
    }

    public static func hello(browserPid: Int32, hostVersion: String) -> Data {
        let m: [String: Any] = ["v": 1, "type": "host_hello", "browserPid": Int(browserPid), "hostVersion": hostVersion]
        return (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data()
    }
}

/// Validates a target URL on the native side. The extension owns the detailed
/// identity policy; the app only rejects obviously unusable input early.
public enum TargetValidation {
    public static func normalize(_ input: String) -> Result<String, TargetError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.count > BridgeProtocol.maxTargetLength { return .failure(.tooLong) }
        let hasScheme = trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        let candidate = hasScheme ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: candidate), let scheme = comps.scheme?.lowercased() else { return .failure(.invalid) }
        guard scheme == "https" || scheme == "http" else { return .failure(.unsupportedScheme) }
        guard comps.user == nil, comps.password == nil else { return .failure(.credentials) }
        guard let host = comps.host, !host.isEmpty, !host.contains(" ") else { return .failure(.invalid) }
        return .success(candidate)
    }

    public enum TargetError: Error, Equatable, CustomStringConvertible {
        case empty, tooLong, invalid, unsupportedScheme, credentials
        public var description: String {
            switch self {
            case .empty: return "Enter a URL to focus on."
            case .tooLong: return "URL is too long."
            case .invalid: return "That does not look like a valid URL."
            case .unsupportedScheme: return "Only http and https pages can be focus targets."
            case .credentials: return "URLs containing credentials are not allowed."
            }
        }
    }
}
