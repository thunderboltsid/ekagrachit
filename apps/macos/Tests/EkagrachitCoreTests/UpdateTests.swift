import Foundation
import XCTest
@testable import EkagrachitCore

final class UpdateTests: XCTestCase {
    let sig = Data(repeating: 7, count: 64).base64EncodedString()
    let sha = String(repeating: "ab", count: 32)

    func manifest(_ version: String = "0.2.0", url: String = "https://github.com/thunderboltsid/ekagrachit/releases/download/v0.2.0/Ekagrachit-0.2.0.zip",
                  sha256: String? = nil, signature: String? = nil, minOS: String? = nil) -> Data {
        try! JSONEncoder().encode(UpdateManifest(version: version, url: url, sha256: sha256 ?? sha, signature: signature ?? sig, minimumSystemVersion: minOS))
    }

    func testVersions() {
        XCTAssertEqual(SemanticVersion("v0.1.3"), SemanticVersion(major: 0, minor: 1, patch: 3))
        XCTAssertTrue(SemanticVersion("0.1.10")! > SemanticVersion("0.1.9")!)
        XCTAssertTrue(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        for bad in ["", "1", "1.2", "1.2.3.4", "1.2.x", "-1.2.3", "1.2.3-beta", "１.2.3"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testOffersOnlyNewerWellFormedUpdates() {
        if case let .available(v, url) = UpdatePolicy.decide(current: "0.1.3", manifestData: manifest()) {
            XCTAssertEqual(v.description, "0.2.0")
            XCTAssertEqual(url.host, "github.com")
        } else { XCTFail("expected an update") }
        XCTAssertEqual(UpdatePolicy.decide(current: "0.2.0", manifestData: manifest()), .upToDate)
        XCTAssertEqual(UpdatePolicy.decide(current: "0.3.0", manifestData: manifest()), .upToDate, "never a downgrade")
    }

    func testRejectsAnythingSuspicious() {
        func rejected(_ d: Data, _ label: String) {
            if case .rejected = UpdatePolicy.decide(current: "0.1.3", manifestData: d) {} else { XCTFail(label) }
        }
        rejected(Data("not json".utf8), "garbage")
        rejected(Data(repeating: 32, count: UpdatePolicy.maxManifestBytes + 1), "oversized")
        rejected(manifest(url: "http://github.com/x.zip"), "plain http")
        rejected(manifest(url: "https://evil.example/x.zip"), "foreign host")
        rejected(manifest(url: "https://github.com.evil.example/x.zip"), "lookalike host")
        rejected(manifest(sha256: "abc"), "short sha")
        rejected(manifest(signature: "not base64!"), "bad signature")
        rejected(manifest(signature: Data(count: 10).base64EncodedString()), "short signature")
        rejected(manifest("0.2"), "bad version")
    }

    func testLocalHTTPOnlyWhenAllowed() {
        let local = manifest(url: "http://127.0.0.1:8123/Ekagrachit.zip")
        if case .rejected = UpdatePolicy.decide(current: "0.1.3", manifestData: local) {} else { XCTFail("local http must be refused by default") }
        if case .available = UpdatePolicy.decide(current: "0.1.3", manifestData: local, allowLocalHTTP: true) {} else { XCTFail("test server allowed") }
    }

    func testMinimumSystemVersion() {
        let d = manifest(minOS: "27.0.0")
        if case .rejected = UpdatePolicy.decide(current: "0.1.3", manifestData: d, systemVersion: SemanticVersion("26.1.0")) {} else { XCTFail() }
        if case .available = UpdatePolicy.decide(current: "0.1.3", manifestData: d, systemVersion: SemanticVersion("27.0.1")) {} else { XCTFail() }
    }
}
