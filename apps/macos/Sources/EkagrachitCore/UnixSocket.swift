import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case sys(String, Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(p): return "socket path too long: \(p)"
        case let .sys(what, err): return "\(what) failed: \(String(cString: strerror(err)))"
        }
    }
}

/// Thin POSIX wrappers for same-user Unix domain sockets. No TCP, ever:
/// the bridge must not be reachable from the network or from other users.
public enum UnixSocket {
    #if canImport(Glibc)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    static let streamType = SOCK_STREAM
    #endif

    private static func makeAddress(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    /// Creates the parent directory with mode 0700, removes a stale socket file,
    /// binds, restricts the socket file to 0600 and listens.
    public static func listen(path: String) throws -> Int32 {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(dir, 0o700)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        unlink(path)
        var (addr, len) = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SocketError.sys("bind", e)
        }
        _ = chmod(path, 0o600)
        guard Glibc_or_Darwin_listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw SocketError.sys("listen", e)
        }
        setCloseOnExec(fd)
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        var (addr, len) = try makeAddress(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc_or_Darwin_connect(fd, $0, len) } }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SocketError.sys("connect", e)
        }
        setNoSigPipe(fd)
        setCloseOnExec(fd)
        return fd
    }

    /// Accepts one pending connection, or nil.
    public static func accept(_ listener: Int32) -> Int32? {
        let fd = Glibc_or_Darwin_accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        setNoSigPipe(fd)
        setCloseOnExec(fd)
        return fd
    }

    /// The effective uid of the process on the other end of a connected socket.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; } (needs _GNU_SOURCE in Glibc headers)
        var cred: (Int32, UInt32, UInt32) = (0, 0, 0)
        var len = socklen_t(MemoryLayout<(Int32, UInt32, UInt32)>.size)
        return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 ? cred.1 : nil
        #endif
    }

    static func setNoSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Blocking write of the whole buffer. Returns false on any error.
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard var p = buf.baseAddress else { return true }
            var remaining = buf.count
            while remaining > 0 {
                #if canImport(Darwin)
                let n = write(fd, p, remaining)
                #else
                var n = send(fd, p, remaining, Int32(MSG_NOSIGNAL))
                if n < 0 && errno == ENOTSOCK { n = write(fd, p, remaining) } // pipes (stdout)
                #endif
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }

    /// Single read; empty Data means EOF, nil means error.
    public static func readChunk(_ fd: Int32, max: Int = 64 * 1024) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = read(fd, &buf, max)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return Data(buf[0..<n])
        }
    }
}

// Disambiguate POSIX functions from same-named Swift methods.
@inline(__always) func Glibc_or_Darwin_listen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
@inline(__always) func Glibc_or_Darwin_connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }
@inline(__always) func Glibc_or_Darwin_accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 { accept(fd, addr, len) }
