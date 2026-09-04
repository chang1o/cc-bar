import Foundation
import SwiftUI

// MARK: - ImportedCodexAccount
//
// 用户手动粘贴 ~/.codex/auth.json 内容导入的"其他 Codex 账号"。
// 与默认账号(实时读 ~/.codex/auth.json)解耦,允许重复(同一账号同时出现在默认槽位和此处)。
// 设计见 docs/技术实现.md "导入账号" 一节。

/// 元数据,持久化到 Application Support/CCBar/imported_codex_accounts.json。
/// Token 三件套不在这里,走 Keychain (见 ImportedCodexStore)。
nonisolated struct ImportedCodexAccount: Sendable, Equatable, Codable, Identifiable {
    /// 复合身份:`{chatgpt_account_id}:{chatgpt_user_id}`。
    /// 仅有 chatgpt_account_id (老数据 / 没拿到 user_id) 时退化为单段。
    /// 同 id 再次粘贴会静默覆盖 token;Team 账号下多个 user 各自独立。
    var id: String
    /// 用户起的别名,空则 UI 上 fallback 到 email。
    var alias: String
    var email: String?
    var planType: String?
    var visibleInPopover: Bool
    var addedAt: Date
    /// 该账号凭据为 Codex personal access token（不透明令牌）。可空以兼容旧数据，nil 视为 false。
    /// 为 true 时刷新走「不续期、直接用令牌」路径，见 [[AppState]].loadImportedCodexQuota。
    var isPersonalAccessToken: Bool? = nil

    /// 从复合 id 还原出用于 `ChatGPT-Account-Id` HTTP header 的纯 account_id。
    var chatgptAccountId: String {
        if let colon = id.firstIndex(of: ":") { return String(id[..<colon]) }
        return id
    }
}

// MARK: - Paste 解析

/// 解析用户粘贴的 auth.json 文本,产出元数据 + token。失败时给明确原因。
enum ImportedCodexPaste {

    struct Parsed: Sendable {
        /// 复合身份,见 `ImportedCodexAccount.id`。
        var id: String
        /// 纯 chatgpt_account_id,用于 HTTP header。
        var chatgptAccountId: String
        var email: String?
        var planType: String?
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case invalidJSON
        case missingTokens
        case missingAccessToken
        case missingAccountId

        var description: String {
            switch self {
            case .invalidJSON:
                return "粘贴内容不是合法 JSON（Paste is not valid JSON）"
            case .missingTokens:
                return "JSON 中缺少 tokens 字段（JSON has no `tokens` field）"
            case .missingAccessToken:
                return "tokens.access_token 缺失（`tokens.access_token` is missing）"
            case .missingAccountId:
                return "无法从 JWT 中提取 chatgpt_account_id（Cannot find chatgpt_account_id in token JWT）"
            }
        }
    }

    /// 识别 personal access token 形态的粘贴：
    /// `{"OPENAI_API_KEY": null, "personal_access_token": "at-..."}`（或裸 `{"personal_access_token": "..."}`）。
    /// 仅在没有 OAuth tokens 时才认作 PAT；命中返回令牌本身。
    /// PAT 是不透明令牌，本地解不出 account_id，身份要在保存时联网取数解析，故走与 `parse` 不同的路径。
    static func personalAccessToken(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if root["tokens"] is [String: Any] || root["access_token"] is String { return nil }
        guard let pat = (root["personal_access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pat.isEmpty
        else { return nil }
        return pat
    }

    /// 批量解析:顶层 JSON 为数组时逐元素解析,跳过失败项,至少有一项成功才返回 .success。
    /// 顶层为对象时退化到 parse()。
    static func parseAny(_ text: String) -> Result<[Parsed], Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return .failure(.invalidJSON) }

        // 尝试数组
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var results: [Parsed] = []
            for element in arr {
                guard let elementData = try? JSONSerialization.data(withJSONObject: element),
                      let elementText = String(data: elementData, encoding: .utf8)
                else { continue }
                if case .success(let p) = parse(elementText) {
                    // 去重按复合 id:同一 account+user 只保留最后一次;
                    // Team 下同 account_id 不同 user_id 视为不同账号,均保留。
                    results.removeAll(where: { $0.id == p.id })
                    results.append(p)
                }
            }
            if results.isEmpty { return .failure(.missingAccountId) }
            return .success(results)
        }

        // 退化到单对象
        return parse(trimmed).map { [$0] }
    }

    /// 兼容两种粘贴形态:
    /// 1. 完整 auth.json (`{OPENAI_API_KEY, tokens: {...}, last_refresh}`)
    /// 2. 裸 tokens 子对象 (`{access_token, refresh_token, id_token, account_id}`)
    static func parse(_ text: String) -> Result<Parsed, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.invalidJSON)
        }

        let tokens: [String: Any]
        if let nested = root["tokens"] as? [String: Any] {
            tokens = nested
        } else if root["access_token"] is String {
            tokens = root
        } else {
            return .failure(.missingTokens)
        }

        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            return .failure(.missingAccessToken)
        }
        let refreshToken = tokens["refresh_token"] as? String
        let idToken = tokens["id_token"] as? String
        let directAccountId = tokens["account_id"] as? String

        // 优先用 tokens.account_id,缺失时再尝试从 access_token / id_token 的 JWT 里抽。
        let chatgptAccountId: String? = directAccountId.flatMap { $0.isEmpty ? nil : $0 }
            ?? extractClaim(from: accessToken, key: "chatgpt_account_id")
            ?? idToken.flatMap { extractClaim(from: $0, key: "chatgpt_account_id") }
        guard let chatgptAccountId else { return .failure(.missingAccountId) }

        // chatgpt_user_id 用于区分同一 Team account 下的不同用户。
        let chatgptUserId: String? = extractClaim(from: accessToken, key: "chatgpt_user_id")
            ?? idToken.flatMap { extractClaim(from: $0, key: "chatgpt_user_id") }

        let compositeId: String = {
            if let userId = chatgptUserId, !userId.isEmpty {
                return "\(chatgptAccountId):\(userId)"
            }
            return chatgptAccountId
        }()

        var email: String?
        var planType: String?
        if let idToken, let claims = JWT.decodePayload(idToken) {
            email = claims["email"] as? String
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                planType = auth["chatgpt_plan_type"] as? String
            }
        }
        if planType == nil, let claims = JWT.decodePayload(accessToken),
           let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
        }

        return .success(Parsed(
            id: compositeId,
            chatgptAccountId: chatgptAccountId,
            email: email,
            planType: planType,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken
        ))
    }

    private static func extractClaim(from jwt: String, key: String) -> String? {
        guard let claims = JWT.decodePayload(jwt) else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let value = auth[key] as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}
