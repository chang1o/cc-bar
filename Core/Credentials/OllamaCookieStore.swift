import Foundation
import Security

/// Manual `Cookie:` header for ollama.com, one per ccpm profile, stored in the app's own
/// Keychain item (SecItem, no authorization prompt).
nonisolated enum OllamaCookieStore {
    nonisolated static let keychainService = "com.cc-bar.ollama.cookie"

    nonisolated static func load(profile: String) -> String? {
        var query = baseQuery(account: profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    nonisolated static func save(_ cookieHeader: String, profile: String) throws {
        let cleaned = normalize(cookieHeader)
        guard !cleaned.isEmpty else {
            delete(profile: profile)
            return
        }
        let data = Data(cleaned.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: profile) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw ImportedCodexStore.KeychainError.unexpected(updateStatus)
        }
        var addQuery = baseQuery(account: profile)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ImportedCodexStore.KeychainError.unexpected(addStatus)
        }
    }

    nonisolated static func delete(profile: String) {
        SecItemDelete(baseQuery(account: profile) as CFDictionary)
    }

    /// Accepts a raw `name=value; name2=value2` header or a pasted `Cookie: ...` line.
    nonisolated static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private nonisolated static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}
