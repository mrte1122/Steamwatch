// Ed25519 signing for update archives. The app embeds the public key and refuses
// any downloaded update whose signature doesn't verify.
//
//   swift scripts/sign-update.swift keygen        create the private key (once) and print the public key
//   swift scripts/sign-update.swift public        print the public key
//   swift scripts/sign-update.swift sign <file>   print the base64 signature of <file>
//
// The private key lives OUTSIDE the repo, at ~/.config/vaporwatch/update-signing-key
// (override with VAPORWATCH_SIGNING_KEY). Back it up: without it you can't ship updates
// that existing installs will accept.
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
// Before the rename the key lived in ~/.config/steamwatch; it's the same key, so either works.
let defaultKey = NSString(string: "~/.config/vaporwatch/update-signing-key").expandingTildeInPath
let legacyKey = NSString(string: "~/.config/steamwatch/update-signing-key").expandingTildeInPath
let keyPath = env["VAPORWATCH_SIGNING_KEY"]
    ?? (FileManager.default.fileExists(atPath: defaultKey) || !FileManager.default.fileExists(atPath: legacyKey) ? defaultKey : legacyKey)
let args = CommandLine.arguments

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyPath). Run: swift scripts/sign-update.swift keygen")
    }
    return key
}

switch args.count > 1 ? args[1] : "" {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath) { fail("A key already exists at \(keyPath); refusing to overwrite it.") }
    let dir = (keyPath as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: keyPath, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 2, let data = FileManager.default.contents(atPath: args[2]) else { fail("usage: sign <file>") }
    print(try! loadKey().signature(for: data).base64EncodedString())
default:
    fail("usage: sign-update.swift keygen | public | sign <file>")
}
