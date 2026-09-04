import Foundation

/// Reads API keys ccpm stored with go-keyring: Keychain generic password, service `ccpm`,
/// account = profile name. Created through the `security` CLI, so reading it back the same
/// way needs no authorization prompt.
nonisolated enum CCPMKeystore {
    nonisolated static let service = "ccpm"
    private static let hexPrefix = "go-keyring-encoded:"
    private static let base64Prefix = "go-keyring-base64:"

    nonisolated static func apiKey(profile: String) -> String? {
        guard let data = SecurityCLI.findGenericPassword(service: service, account: profile),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let decoded = decode(raw)
        return decoded.isEmpty ? nil : decoded
    }

    nonisolated static func credential(for profile: CCPMProfile) -> String? {
        apiKey(profile: profile.name)
    }

    /// go-keyring wraps values as `go-keyring-base64:<b64>` (current) or
    /// `go-keyring-encoded:<hex>` (legacy); anything else is returned as is.
    nonisolated static func decode(_ raw: String) -> String {
        if raw.hasPrefix(base64Prefix) {
            let body = String(raw.dropFirst(base64Prefix.count))
            if let data = Data(base64Encoded: body), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return raw
        }
        if raw.hasPrefix(hexPrefix) {
            let body = String(raw.dropFirst(hexPrefix.count))
            var bytes: [UInt8] = []
            var index = body.startIndex
            while index < body.endIndex {
                guard let next = body.index(index, offsetBy: 2, limitedBy: body.endIndex),
                      let byte = UInt8(body[index..<next], radix: 16)
                else { return raw }
                bytes.append(byte)
                index = next
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return raw
    }
}
