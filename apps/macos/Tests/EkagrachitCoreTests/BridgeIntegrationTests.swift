import XCTest
@testable import EkagrachitCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Real Unix sockets and the real ekagrachit-host binary (Test F + bridge).
final class BridgeIntegrationTests: XCTestCase {
    var dir: URL!
    var socketPath: String { dir.appendingPathComponent("b.sock").path }
    let queue = DispatchQueue(label: "test.delivery")

    override func setUp() {
        // Short path: sun_path is limited to ~104 bytes.
        dir = URL(fileURLWithPath: "/tmp/ek-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testServerAcceptsSameUserClientsAndParsesFrames() throws {
        let server = BridgeServer(path: socketPath, deliveryQueue: queue)
        let got = expectation(description: "message")
        var received: [AppInbound] = []
        server.onMessage = { msg, _ in
            received.append(msg)
            if received.count == 2 { got.fulfill() }
        }
        try server.start()
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "socket directory is private")

        let fd = try UnixSocket.connect(path: socketPath)
        defer { close(fd) }
        XCTAssertTrue(UnixSocket.writeAll(fd, Framing.encode(Data("garbage".utf8))))
        XCTAssertTrue(UnixSocket.writeAll(fd, Framing.encode(Data("{\"type\":\"evil\"}".utf8))))
        XCTAssertTrue(UnixSocket.writeAll(fd, Framing.encode(HostMessages.hello(browserPid: 4242, hostVersion: "t"))))
        XCTAssertTrue(UnixSocket.writeAll(fd, Framing.encode(Data("{\"type\":\"end_request\",\"sid\":\"0123456789abcdef\"}".utf8))))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(received, [.hostHello(browserPid: 4242, hostVersion: "t"), .endRequest(sid: "0123456789abcdef")])
        queue.sync { XCTAssertEqual(server.malformedMessages, 2) }
        queue.sync { server.stop() }
    }

    func testOversizedFrameClosesTheConnection() throws {
        let server = BridgeServer(path: socketPath, deliveryQueue: queue)
        let disconnected = expectation(description: "disconnect")
        server.onDisconnect = { _ in disconnected.fulfill() }
        try server.start()
        let fd = try UnixSocket.connect(path: socketPath)
        defer { close(fd) }
        var len = UInt32(50 << 20).littleEndian
        _ = UnixSocket.writeAll(fd, Data(bytes: &len, count: 4))
        wait(for: [disconnected], timeout: 5)
        queue.sync { server.stop() }
    }

    /// Full relay: test acts as Chrome (stdio) and as the app (socket server).
    func testNativeHostRelaysBothWays() throws {
        let hostURL = try XCTUnwrap(Self.hostBinary(), "ekagrachit-host binary not found; run `swift build` first")
        let server = BridgeServer(path: socketPath, deliveryQueue: queue)
        var conn: BridgeServer.ConnectionID?
        var received: [AppInbound] = []
        let helloSeen = expectation(description: "host_hello")
        let extMsg = expectation(description: "extension message relayed")
        server.onConnect = { conn = $0 }
        server.onMessage = { msg, _ in
            received.append(msg)
            if case .hostHello = msg { helloSeen.fulfill() }
            if case .endRequest = msg { extMsg.fulfill() }
        }
        try server.start()

        let proc = Process()
        proc.executableURL = hostURL
        proc.arguments = ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]
        var env = ProcessInfo.processInfo.environment
        env["EKAGRACHIT_SOCKET"] = socketPath
        proc.environment = env
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        try proc.run()
        defer { if proc.isRunning { proc.terminate() } }

        // Chrome side: read host_status
        var decoder = FrameDecoder()
        func readFrame() throws -> [String: Any] {
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                XCTAssertFalse(chunk.isEmpty, "host closed stdout")
                if chunk.isEmpty { throw NSError(domain: "eof", code: 1) }
                if let f = try decoder.feed(chunk).first {
                    return try XCTUnwrap(try JSONSerialization.jsonObject(with: f) as? [String: Any])
                }
            }
        }
        let status = try readFrame()
        XCTAssertEqual(status["type"] as? String, "host_status")
        XCTAssertEqual(status["appConnected"] as? Bool, true)
        wait(for: [helloSeen], timeout: 5)

        // extension -> app
        stdin.fileHandleForWriting.write(Framing.encode(Data("{\"v\":1,\"type\":\"end_request\",\"sid\":\"0123456789abcdef\"}".utf8)))
        stdin.fileHandleForWriting.write(Framing.encode(Data("not json".utf8))) // dropped by host
        wait(for: [extMsg], timeout: 5)

        // app -> extension
        queue.sync { server.send(.focus(sid: "0123456789abcdef"), to: conn!) }
        let focus = try readFrame()
        XCTAssertEqual(focus["type"] as? String, "focus")

        // app goes away -> host reports it
        queue.sync { server.stop() }
        let down = try readFrame()
        XCTAssertEqual(down["type"] as? String, "host_status")
        XCTAssertEqual(down["appConnected"] as? Bool, false)

        // Chrome closes stdin -> host exits
        stdin.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(proc.isRunning, "host exits when Chrome closes the port")
    }

    static func hostBinary() -> URL? {
        if let env = ProcessInfo.processInfo.environment["EKAGRACHIT_HOST_BINARY"] { return URL(fileURLWithPath: env) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        let fm = FileManager.default
        var candidates = [build.appendingPathComponent("debug/ekagrachit-host"), build.appendingPathComponent("release/ekagrachit-host")]
        for triple in (try? fm.contentsOfDirectory(atPath: build.path)) ?? [] {
            candidates.append(build.appendingPathComponent("\(triple)/debug/ekagrachit-host"))
            candidates.append(build.appendingPathComponent("\(triple)/release/ekagrachit-host"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
