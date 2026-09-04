import Foundation

nonisolated enum ClaudeQuotaClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "claude-code/2.1.0"

    nonisolated static func fetch(
        accessToken: String
    ) async -> Result<QuotaSnapshot, QuotaError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30

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

    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("claude: not a json object")
        }
        return QuotaSnapshot(
            provider: .claude,
            primary: parseWindow(root["five_hour"] as? [String: Any], kind: .fiveHour),
            secondary: parseWindow(root["seven_day"] as? [String: Any], kind: .weekly),
            extra: [
                parseWindow(root["seven_day_opus"] as? [String: Any], kind: .weeklyOpus),
                parseWindow(root["seven_day_sonnet"] as? [String: Any], kind: .weeklySonnet),
                parseExtraUsage(root["extra_usage"] as? [String: Any])
            ].compactMap { $0 },
            planType: nil,
            fetchedAt: now
        )
    }

    /// `extra_usage` is the pay-as-you-go overage cap. Amounts arrive in minor
    /// units (cents), the same convention CodexBar follows for OAuth and Web.
    nonisolated private static func parseExtraUsage(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict, (dict["is_enabled"] as? Bool) == true,
              let limitMinor = QuotaJSON.double(dict["monthly_limit"]), limitMinor > 0
        else { return nil }
        let usedMinor = QuotaJSON.double(dict["used_credits"]) ?? 0
        let used = usedMinor / 100
        let limit = limitMinor / 100
        let percent = QuotaJSON.double(dict["utilization"]) ?? (used / limit * 100)
        let symbol = currencySymbol(dict["currency"] as? String)
        return QuotaWindow(
            kind: .extraUsage,
            usedPercent: percent,
            resetsAt: nil,
            windowSeconds: nil,
            detail: "\(symbol)\(String(format: "%.2f", used)) / \(symbol)\(String(format: "%.2f", limit))"
        )
    }

    nonisolated private static func currencySymbol(_ code: String?) -> String {
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case nil, "", "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY", "CNY": return "¥"
        case let other?: return other + " "
        }
    }

    nonisolated private static func parseWindow(_ dict: [String: Any]?, kind: QuotaWindowKind) -> QuotaWindow? {
        guard let dict else { return nil }
        let used: Double = {
            if let d = dict["utilization"] as? Double { return d }
            if let i = dict["utilization"] as? Int { return Double(i) }
            return 0
        }()
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) {
                resetsAt = d
            } else {
                iso.formatOptions = [.withInternetDateTime]
                resetsAt = iso.date(from: s)
            }
        } else if let n = dict["resets_at"] as? Double {
            resetsAt = Date(timeIntervalSince1970: n)
        } else if let i = dict["resets_at"] as? Int {
            resetsAt = Date(timeIntervalSince1970: Double(i))
        }
        return QuotaWindow(kind: kind, usedPercent: used, resetsAt: resetsAt, windowSeconds: kind.defaultSeconds)
    }
}
