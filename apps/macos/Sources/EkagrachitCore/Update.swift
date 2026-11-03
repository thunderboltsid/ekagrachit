import Foundation

/// A release version, "major.minor.patch" (a leading "v" is accepted).
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]),
              a >= 0, b >= 0, c >= 0,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        self.init(major: a, minor: b, patch: c)
    }

    public static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// `update.json`, published with every release:
/// the app archive's URL, its SHA-256, and an Ed25519 signature of the archive
/// made with the release key (whose public half is built into the app).
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var url: String
    public var sha256: String
    public var signature: String
    public var minimumSystemVersion: String?

    public init(version: String, url: String, sha256: String, signature: String, minimumSystemVersion: String? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.signature = signature
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(version: SemanticVersion, archive: URL)
    case rejected(String)
}

public enum UpdatePolicy {
    /// Hosts an update archive may come from (GitHub release assets redirect
    /// to the objects host).
    public static let allowedHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
    public static let maxManifestBytes = 16 * 1024

    /// Decides what to do with a downloaded manifest. Never offers a
    /// downgrade or the running version, and refuses anything malformed.
    /// `allowLocalHTTP` is for the end-to-end test only (a local server).
    public static func decide(current: String, manifestData: Data, systemVersion: SemanticVersion? = nil,
                              allowLocalHTTP: Bool = false) -> UpdateDecision {
        guard manifestData.count <= maxManifestBytes,
              let m = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        else { return .rejected("malformed manifest") }
        guard let have = SemanticVersion(current) else { return .rejected("unknown current version \(current)") }
        guard let offered = SemanticVersion(m.version) else { return .rejected("malformed version \(m.version)") }
        guard offered > have else { return .upToDate }
        guard let url = URL(string: m.url), let host = url.host?.lowercased() else { return .rejected("malformed URL") }
        let local = allowLocalHTTP && url.scheme == "http" && (host == "127.0.0.1" || host == "localhost")
        guard local || (url.scheme == "https" && allowedHosts.contains(host)) else { return .rejected("archive host not allowed: \(host)") }
        guard m.sha256.count == 64, m.sha256.allSatisfy(\.isHexDigit) else { return .rejected("malformed sha256") }
        guard let sig = Data(base64Encoded: m.signature), sig.count == 64 else { return .rejected("malformed signature") }
        if let min = m.minimumSystemVersion.flatMap(SemanticVersion.init), let sys = systemVersion, sys < min {
            return .rejected("needs macOS \(min)")
        }
        return .available(version: offered, archive: url)
    }

    /// Lowercase hex, for comparing with `sha256`.
    public static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
