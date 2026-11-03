import XCTest
@testable import EkagrachitCore

final class NativeHostRegistrationTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testManifestAllowsOnlyTheExtension() throws {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: NativeHostRegistration.manifest(hostPath: "/Applications/Ekagrachit.app/Contents/MacOS/ekagrachit-host")) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "io.github.thunderboltsid.ekagrachit")
        XCTAssertEqual(obj["type"] as? String, "stdio")
        XCTAssertEqual(obj["path"] as? String, "/Applications/Ekagrachit.app/Contents/MacOS/ekagrachit-host")
        XCTAssertEqual(obj["allowed_origins"] as? [String], ["chrome-extension://dpbpdbflelamfpmehknioljngeaagaeb/"])
    }

    func testRegistersChromeAndInstalledBrowsersOnlyAndIsIdempotent() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)
        let first = NativeHostRegistration.register(hostPath: "/A/host", applicationSupport: root)
        XCTAssertEqual(Set(first.written), ["Google/Chrome", "BraveSoftware/Brave-Browser"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Microsoft Edge").path), "absent browsers are not created")
        let second = NativeHostRegistration.register(hostPath: "/A/host", applicationSupport: root)
        XCTAssertEqual(second.written, [])
        XCTAssertEqual(Set(second.unchanged), ["Google/Chrome", "BraveSoftware/Brave-Browser"])
        // App moved: manifests are rewritten.
        let moved = NativeHostRegistration.register(hostPath: "/B/host", applicationSupport: root)
        XCTAssertEqual(Set(moved.written), ["Google/Chrome", "BraveSoftware/Brave-Browser"])
        let data = try Data(contentsOf: root.appendingPathComponent("Google/Chrome/NativeMessagingHosts/io.github.thunderboltsid.ekagrachit.json"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/B/host"))
    }

    func testExtensionSyncCopiesOnlyWhenChanged() throws {
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data("{\"version\":\"1\"}".utf8).write(to: src.appendingPathComponent("manifest.json"))
        try Data("a".utf8).write(to: src.appendingPathComponent("icons/16.png"))
        let dst = root.appendingPathComponent("support/Chrome Extension")
        XCTAssertTrue(try NativeHostRegistration.syncExtension(from: src, to: dst))
        XCTAssertFalse(try NativeHostRegistration.syncExtension(from: src, to: dst), "unchanged: no copy, no reload prompt")
        try Data("{\"version\":\"2\"}".utf8).write(to: src.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try NativeHostRegistration.syncExtension(from: src, to: dst))
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("manifest.json"), encoding: .utf8), "{\"version\":\"2\"}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("icons/16.png").path))
        XCTAssertFalse(try NativeHostRegistration.syncExtension(from: root.appendingPathComponent("missing"), to: dst))
    }
}
