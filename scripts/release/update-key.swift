// Ed25519 tooling for automatic updates (CryptoKit, macOS).
//   swift scripts/release/update-key.swift new            -> new private key (base64, raw 32 bytes) on stdout
//   swift scripts/release/update-key.swift public         -> public key for $UPDATE_SIGNING_KEY
//   swift scripts/release/update-key.swift sign FILE      -> base64 signature of FILE with $UPDATE_SIGNING_KEY
// The private key only ever comes from the environment; nothing is written to disk.
import CryptoKit
import Foundation

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("update-key: \(s)\n".utf8))
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let s = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
          let raw = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("UPDATE_SIGNING_KEY is missing or not a base64 Ed25519 key") }
    return key
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "new":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 2, let data = FileManager.default.contents(atPath: args[2]) else { fail("usage: sign FILE") }
    let key = privateKey()
    let sig = try key.signature(for: data)
    guard key.publicKey.isValidSignature(sig, for: data) else { fail("self-check failed") }
    print(sig.base64EncodedString())
default:
    fail("usage: new | public | sign FILE")
}
