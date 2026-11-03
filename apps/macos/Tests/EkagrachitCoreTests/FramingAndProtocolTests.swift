import XCTest
@testable import EkagrachitCore

final class FramingTests: XCTestCase {
    func testRoundTripAcrossArbitraryChunks() throws {
        let msgs = [Data("{\"type\":\"a\"}".utf8), Data(), Data(repeating: 65, count: 70_000)]
        var stream = Data()
        msgs.forEach { stream.append(Framing.encode($0)) }
        var decoder = FrameDecoder()
        var out: [Data] = []
        var i = 0
        while i < stream.count {
            let n = min(7, stream.count - i)
            out += try decoder.feed(stream.subdata(in: i..<(i + n)))
            i += n
        }
        XCTAssertEqual(out, msgs)
    }

    func testLittleEndianLengthPrefix() {
        XCTAssertEqual([UInt8](Framing.encode(Data([1, 2, 3])).prefix(4)), [3, 0, 0, 0])
    }

    func testRejectsOversizedFrames() {
        var decoder = FrameDecoder(maxSize: 10)
        var header = UInt32(11).littleEndian
        XCTAssertThrowsError(try decoder.feed(Data(bytes: &header, count: 4)))
    }
}

final class ProtocolTests: XCTestCase {
    let sid = "0123456789abcdef"

    func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testParsesValidMessages() {
        XCTAssertEqual(AppInbound.parse(json(["type": "host_hello", "browserPid": 123, "hostVersion": "0.1.0"])), .hostHello(browserPid: 123, hostVersion: "0.1.0"))
        XCTAssertEqual(
            AppInbound.parse(json(["type": "window_ready", "sid": sid, "windowId": 5, "tabId": 6, "bounds": ["left": 10, "top": 20, "width": 800, "height": 600], "state": "normal"])),
            .windowReady(sid: sid, windowId: 5, tabId: 6, bounds: Rect(x: 10, y: 20, width: 800, height: 600), state: "normal")
        )
        XCTAssertEqual(
            AppInbound.parse(json(["type": "hello", "protocol": 1, "extVersion": "0.1.0", "extensionId": "abc", "standalone": ["sid": sid, "target": "https://x", "remainingMs": 1000]])),
            .hello(protocolVersion: 1, extVersion: "0.1.0", extensionId: "abc", standalone: StandaloneSession(sid: sid, target: "https://x", remainingMs: 1000))
        )
        XCTAssertEqual(AppInbound.parse(json(["type": "hello", "protocol": 1, "standalone": NSNull()])),
                       .hello(protocolVersion: 1, extVersion: "unknown", extensionId: "", standalone: nil))
    }

    func testParsesV1Additions() {
        XCTAssertEqual(AppInbound.parse(json(["type": "violation", "sid": sid, "kind": "tab_closed", "host": "acme.atlassian.net"])),
                       .violation(sid: sid, kind: "tab_closed", host: "acme.atlassian.net"))
        XCTAssertEqual(AppInbound.parse(json(["type": "violation", "sid": sid, "kind": "tab_closed"])),
                       .violation(sid: sid, kind: "tab_closed", host: nil))
        XCTAssertEqual(AppInbound.parse(json(["type": "active_tab", "cid": "c1", "url": "https://x.example/"])), .activeTab(cid: "c1", url: "https://x.example/"))
        XCTAssertNil(AppInbound.parse(json(["type": "active_tab", "cid": "c1"])))
        XCTAssertEqual(AppInbound.parse(json(["v": 1, "type": "show_menu"])), .showMenu)
        let reload = try! JSONSerialization.jsonObject(with: AppOutbound.reload.encoded()) as! [String: Any]
        XCTAssertEqual(reload["type"] as? String, "reload")
    }

    func testRejectsMalformedMessages() {
        let bad: [Data] = [
            Data("not json".utf8), Data("[]".utf8), Data("{}".utf8),
            json(["type": "unknown"]),
            json(["type": "end_request"]),
            json(["type": "end_request", "sid": "short"]),
            json(["type": "end_request", "sid": "../../../../etc/passwd"]),
            json(["type": "window_ready", "sid": sid, "windowId": 1, "tabId": 2, "bounds": ["left": 0, "top": 0, "width": -1, "height": 10]]),
            json(["type": "window_ready", "sid": sid, "windowId": 1.5, "tabId": 2, "bounds": ["left": 0, "top": 0, "width": 1, "height": 1]]),
            json(["type": "host_hello", "browserPid": -4]),
            json(["type": "start_request", "cid": "c", "target": String(repeating: "x", count: 5000), "durationMinutes": 25]),
            json(["type": "hello", "protocol": 1, "standalone": ["sid": sid, "target": "x", "remainingMs": -1]]),
        ]
        for b in bad { XCTAssertNil(AppInbound.parse(b), String(decoding: b, as: UTF8.self)) }
    }

    func testEncodesSync() throws {
        let data = AppOutbound.sync(epoch: "e", seq: 3, session: DesiredSession(sid: sid, target: "https://x", remainingMs: 1234.4, phase: "active")).encoded()
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["type"] as? String, "sync")
        XCTAssertEqual(o["seq"] as? Int, 3)
        let s = try XCTUnwrap(o["session"] as? [String: Any])
        XCTAssertEqual(s["remainingMs"] as? Double, 1234)
        let none = try XCTUnwrap(try JSONSerialization.jsonObject(with: AppOutbound.sync(epoch: "e", seq: 4, session: nil).encoded()) as? [String: Any])
        XCTAssertTrue(none["session"] is NSNull)
    }

    func testTargetValidation() {
        XCTAssertEqual(try TargetValidation.normalize(" docs.google.com/document/d/x ").get(), "https://docs.google.com/document/d/x")
        XCTAssertEqual(TargetValidation.normalize(""), .failure(.empty))
        XCTAssertEqual(TargetValidation.normalize("javascript:alert(1)"), .failure(.unsupportedScheme))
        XCTAssertEqual(TargetValidation.normalize("file:///etc/passwd"), .failure(.unsupportedScheme))
        XCTAssertEqual(TargetValidation.normalize("https://u:p@example.com/"), .failure(.credentials))
    }
}
