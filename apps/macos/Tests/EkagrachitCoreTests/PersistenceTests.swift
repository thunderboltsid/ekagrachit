import XCTest
@testable import EkagrachitCore

final class PersistenceTests: XCTestCase {
    func testSaveLoadClear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        XCTAssertNil(store.load())
        let p = PersistedSession(sid: "0123456789abcdef", target: "https://x", startedAt: 1, deadline: Deadline(start: SystemClock.shared.now(), duration: 60))
        try store.save(p)
        XCTAssertEqual(store.load(), p)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.clear()
        XCTAssertNil(store.load())
        store.clear() // idempotent
    }

    func testCorruptFileIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.json")
        try Data("{garbage".utf8).write(to: url)
        XCTAssertNil(SessionStore(url: url).load())
    }
}
