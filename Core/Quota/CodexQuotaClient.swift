import Foundation

nonisolated enum CodexQuotaClient {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    nonisolated static func fetch(
        accessToken: String,
        accountId: String?
    ) async -> Result<QuotaSnapshot, QuotaError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, msg))
        }
        do {
            return .success(try parse(data: data))
        } catch let error as QuotaError {
            return .failure(error)
        } catch {
            return .failure(.decode("\(error)"))
        }
    }

    /// `rate_limit.primary_window` / `secondary_window` are positional in the API;
    /// the actual cadence comes from `limit_window_seconds`. Pro 20x, for example,
    /// carries a single weekly window and no session window at all.
    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("codex: not a json object")
        }
        let planType = root["plan_type"] as? String
        let rate = root["rate_limit"] as? [String: Any] ?? [:]
        let windows = [
            parseWindow(rate["primary_window"] as? [String: Any], fallbackKind: .fiveHour, now: now),
            parseWindow(rate["secondary_window"] as? [String: Any], fallbackKind: .weekly, now: now)
        ].compactMap { $0 }
        // Session lane first when both exist, regardless of API position.
        let ordered = windows.sorted { ($0.windowSeconds ?? 0) < ($1.windowSeconds ?? 0) }
        return QuotaSnapshot(
            provider: .codex,
            primary: ordered.first,
            secondary: ordered.count > 1 ? ordered[1] : nil,
            extra: [],
            planType: planType,
            fetchedAt: now
        )
    }

    nonisolated private static func parseWindow(
        _ dict: [String: Any]?,
        fallbackKind: QuotaWindowKind,
        now: Date
    ) -> QuotaWindow? {
        guard let dict else { return nil }
        let used: Double = {
            if let d = dict["used_percent"] as? Double { return d }
            if let i = dict["used_percent"] as? Int { return Double(i) }
            return 0
        }()
        var resetAt: Date?
        if let n = dict["reset_at"] as? Double {
            resetAt = Date(timeIntervalSince1970: n)
        } else if let i = dict["reset_at"] as? Int {
            resetAt = Date(timeIntervalSince1970: Double(i))
        } else if let secs = dict["reset_after_seconds"] as? Double {
            resetAt = now.addingTimeInterval(secs)
        } else if let secs = dict["reset_after_seconds"] as? Int {
            resetAt = now.addingTimeInterval(Double(secs))
        }
        let window: Int? = (dict["limit_window_seconds"] as? Int)
            ?? (dict["limit_window_seconds"] as? Double).map { Int($0) }
        return QuotaWindow(kind: kind(forWindowSeconds: window, fallback: fallbackKind), usedPercent: used, resetsAt: resetAt, windowSeconds: window)
    }

    nonisolated static func kind(forWindowSeconds seconds: Int?, fallback: QuotaWindowKind) -> QuotaWindowKind {
        guard let seconds, seconds > 0 else { return fallback }
        if seconds <= 6 * 3600 { return .fiveHour }
        if seconds >= 6 * 86400 && seconds <= 8 * 86400 { return .weekly }
        if seconds > 8 * 86400 { return .monthly }
        return fallback
    }
}
