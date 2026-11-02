import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One framed, bidirectional socket connection. Reads on `ioQueue`, delivers
/// frames on `deliveryQueue`, writes on `ioQueue` (never blocks the caller).
public final class FramedConnection: @unchecked Sendable {
    public let fd: Int32
    private let ioQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private var source: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private var closed = false
    private let lock = NSLock()
    public var onFrame: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    public init(fd: Int32, ioQueue: DispatchQueue, deliveryQueue: DispatchQueue) {
        self.fd = fd
        self.ioQueue = ioQueue
        self.deliveryQueue = deliveryQueue
    }

    public func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in Glibc_or_Darwin_close(fd) }
        source = src
        src.resume()
    }

    private func readAvailable() {
        guard let chunk = UnixSocket.readChunk(fd), !chunk.isEmpty else {
            close()
            return
        }
        do {
            let frames = try decoder.feed(chunk)
            for f in frames {
                deliveryQueue.async { [weak self] in self?.onFrame?(f) }
            }
        } catch {
            close() // oversized frame: protocol violation
        }
    }

    public func send(_ payload: Data) {
        let framed = Framing.encode(payload)
        ioQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            if !UnixSocket.writeAll(self.fd, framed) { self.close() }
        }
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    public func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        if let source {
            source.cancel()
        } else {
            Glibc_or_Darwin_close(fd)
        }
        deliveryQueue.async { [weak self] in self?.onClose?() }
    }
}

@inline(__always) func Glibc_or_Darwin_close(_ fd: Int32) { _ = close(fd) }

/// Listens on the bridge socket and turns frames into `AppInbound` messages.
///
/// Authentication: the socket lives in a 0700 directory, the socket file is
/// 0600, and every accepted peer's effective uid must equal ours. Any process
/// running as the same user is inside the trust boundary (it could equally
/// kill or reconfigure the app), so no further secret is used.
public final class BridgeServer: @unchecked Sendable {
    public typealias ConnectionID = Int

    public let path: String
    private let ioQueue = DispatchQueue(label: "ekagrachit.bridge.io")
    private let deliveryQueue: DispatchQueue
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ConnectionID: FramedConnection] = [:]
    private var nextID = 1
    public private(set) var rejectedPeers = 0
    public private(set) var malformedMessages = 0

    /// Called on `deliveryQueue`.
    public var onMessage: ((AppInbound, ConnectionID) -> Void)?
    public var onConnect: ((ConnectionID) -> Void)?
    public var onDisconnect: ((ConnectionID) -> Void)?

    public init(path: String, deliveryQueue: DispatchQueue = .main) {
        self.path = path
        self.deliveryQueue = deliveryQueue
    }

    public func start() throws {
        listenFD = try UnixSocket.listen(path: path)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { [fd = listenFD] in Glibc_or_Darwin_close(fd) }
        acceptSource = src
        src.resume()
    }

    /// Must be called on `deliveryQueue`.
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
        connections.values.forEach { $0.close() }
    }

    private func acceptPending() {
        guard let fd = UnixSocket.accept(listenFD) else { return }
        guard let uid = UnixSocket.peerUID(fd), uid == geteuid() else {
            Glibc_or_Darwin_close(fd)
            deliveryQueue.async { self.rejectedPeers += 1 }
            return
        }
        let conn = FramedConnection(fd: fd, ioQueue: ioQueue, deliveryQueue: deliveryQueue)
        deliveryQueue.async {
            let id = self.nextID
            self.nextID += 1
            self.connections[id] = conn
            conn.onFrame = { [weak self] data in
                guard let self else { return }
                if let msg = AppInbound.parse(data) {
                    self.onMessage?(msg, id)
                } else {
                    self.malformedMessages += 1
                }
            }
            conn.onClose = { [weak self] in
                guard let self, self.connections.removeValue(forKey: id) != nil else { return }
                self.onDisconnect?(id)
            }
            self.onConnect?(id)
            conn.start()
        }
    }

    /// Must be called on `deliveryQueue`.
    public func send(_ msg: AppOutbound, to id: ConnectionID) {
        connections[id]?.send(msg.encoded())
    }

    /// Must be called on `deliveryQueue`.
    public func disconnect(_ id: ConnectionID) {
        connections[id]?.close()
    }

    public var connectionIDs: [ConnectionID] { Array(connections.keys).sorted() }
}
