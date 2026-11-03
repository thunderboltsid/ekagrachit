import Foundation

/// The minimum state persisted to survive an app restart. No URLs other than
/// the target, no history, no content.
public struct PersistedSession: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sid: String
    public var target: String
    public var startedAt: TimeInterval
    public var deadline: Deadline
    /// Native-window target (absent for web sessions and older files).
    public var app: NativeWindowTarget?

    public init(sid: String, target: String, startedAt: TimeInterval, deadline: Deadline, app: NativeWindowTarget? = nil) {
        self.sid = sid
        self.target = target
        self.startedAt = startedAt
        self.deadline = deadline
        self.app = app
    }
}

/// Atomic JSON file store (write to temp + rename), mode 0600.
public struct SessionStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PersistedSession? {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(PersistedSession.self, from: data),
              p.version == 1, BridgeProtocol.isValidSid(p.sid)
        else { return nil }
        return p
    }

    public func save(_ p: PersistedSession) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(p)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum Paths {
    /// ~/Library/Application Support/Ekagrachit (macOS) or $XDG_DATA_HOME/ekagrachit (Linux, tests).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["EKAGRACHIT_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ekagrachit", isDirectory: true)
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        return xdg.appendingPathComponent("ekagrachit", isDirectory: true)
        #endif
    }

    /// The host <-> app Unix socket. Its directory is 0700 so only this user can reach it.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["EKAGRACHIT_SOCKET"], !override.isEmpty { return override }
        return supportDirectory.appendingPathComponent("bridge.sock").path
    }

    public static var sessionFile: URL {
        supportDirectory.appendingPathComponent("session.json")
    }
}
