import Foundation
import XCTest
@testable import EkagrachitCore

final class SocketTimeoutTests: XCTestCase {
    /// A peer that never reads must not block the app's writer forever.
    func testWritesToAPeerThatNeverReadsFailWithinSeconds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ek-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s").path
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener) }
        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        var accepted: Int32?
        for _ in 0..<50 where accepted == nil {
            accepted = UnixSocket.accept(listener)
            if accepted == nil { usleep(10_000) }
        }
        let server = try XCTUnwrap(accepted)
        defer { close(server) }
        let chunk = Data(repeating: 0x61, count: 256 * 1024)
        let start = Date()
        var ok = true
        for _ in 0..<64 where ok { ok = UnixSocket.writeAll(server, chunk) } // far more than any socket buffer
        XCTAssertFalse(ok, "write to a stalled peer should fail")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6, "and fail within the send timeout")
    }
}
