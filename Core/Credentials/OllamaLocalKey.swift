import CryptoKit
import Foundation

/// The local Ollama identity: the unencrypted OpenSSH ed25519 key the CLI and the desktop
/// app use to sign requests to ollama.com. Read-only; the key never leaves the machine,
/// only signatures over `"<METHOD>,<PATH>?ts=<unix seconds>"` do.
nonisolated struct OllamaLocalKey: Sendable {
    enum LoadError: Error, CustomStringConvertible {
        case notOpenSSH
        case encrypted
        case unsupportedKeyType(String)
        case malformed

        var description: String {
            switch self {
            case .notOpenSSH: return "ollama key: not an OpenSSH private key"
            case .encrypted: return "ollama key: passphrase-protected keys are not supported"
            case .unsupportedKeyType(let type): return "ollama key: unsupported key type \(type)"
            case .malformed: return "ollama key: malformed"
            }
        }
    }

    /// Base64 of the SSH public key blob (the second field of `id_ed25519.pub`).
    let publicKeyBase64: String
    private let privateKey: Curve25519.Signing.PrivateKey

    nonisolated static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/id_ed25519")
    }

    nonisolated static func load(url: URL = defaultURL()) throws -> OllamaLocalKey {
        try parse(pem: try String(contentsOf: url, encoding: .utf8))
    }

    nonisolated static func parse(pem: String) throws -> OllamaLocalKey {
        let body = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw LoadError.notOpenSSH }
        var reader = BlobReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.count > magic.count, data.prefix(magic.count) == magic else { throw LoadError.notOpenSSH }
        reader.skip(magic.count)

        let cipher = try reader.string()
        _ = try reader.string() // kdf name
        _ = try reader.string() // kdf options
        guard cipher == "none" else { throw LoadError.encrypted }
        guard try reader.uint32() == 1 else { throw LoadError.malformed }
        let publicBlob = try reader.bytes()
        let privateSection = try reader.bytes()

        var priv = BlobReader(privateSection)
        _ = try priv.uint32() // check int 1
        _ = try priv.uint32() // check int 2
        let keyType = try priv.string()
        guard keyType == "ssh-ed25519" else { throw LoadError.unsupportedKeyType(keyType) }
        _ = try priv.bytes() // public key (32 bytes), repeated below
        let secret = try priv.bytes() // 64 bytes: seed + public key
        guard secret.count == 64 else { throw LoadError.malformed }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
        return OllamaLocalKey(publicKeyBase64: publicBlob.base64EncodedString(), privateKey: key)
    }

    /// Mirrors `auth.Sign` in the Ollama Go client: `<pubkey>:<base64(signature)>`.
    nonisolated static func challenge(method: String, path: String, ts: String) -> String {
        "\(method),\(path)?ts=\(ts)"
    }

    nonisolated func authorization(method: String, path: String, ts: String) throws -> String {
        let challenge = Self.challenge(method: method, path: path, ts: ts)
        let signature = try privateKey.signature(for: Data(challenge.utf8))
        return "\(publicKeyBase64):\(signature.base64EncodedString())"
    }

    /// Verification helper for tests and self-checks.
    nonisolated func verify(signatureBase64: String, method: String, path: String, ts: String) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else { return false }
        let challenge = Self.challenge(method: method, path: path, ts: ts)
        return privateKey.publicKey.isValidSignature(signature, for: Data(challenge.utf8))
    }

    /// Big-endian length-prefixed SSH wire format reader.
    private struct BlobReader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func skip(_ count: Int) {
            offset += count
        }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= data.endIndex else { throw LoadError.malformed }
            let value = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 4
            return value
        }

        mutating func bytes() throws -> Data {
            let length = Int(try uint32())
            guard length >= 0, offset + length <= data.endIndex else { throw LoadError.malformed }
            let slice = Data(data[offset..<offset + length])
            offset += length
            return slice
        }

        mutating func string() throws -> String {
            guard let text = String(data: try bytes(), encoding: .utf8) else { throw LoadError.malformed }
            return text
        }
    }
}

/// Whether Ollama has ever run on this Mac: the CLI and the desktop app both create the key
/// on first launch, signed in or not.
nonisolated enum OllamaInstall {
    nonisolated static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: OllamaLocalKey.defaultURL().path)
    }
}
