import Foundation

/// GLM Coding Plan quota: `GET {host}/api/monitor/usage/quota/limit` with the
/// coding-plan API key. Host follows `ANTHROPIC_BASE_URL` (open.bigmodel.cn or api.z.ai).
nonisolated enum GLMQuotaClient {
    nonisolated static func quotaURL(baseURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = "/api/monitor/usage/quota/limit"
        return components.url ?? URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    }

    nonisolated static func fetch(apiKey: String, baseURL: URL) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: quotaURL(baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.http(http.statusCode, String(data: data, encoding: .utf8) ?? ""))
        }
        do {
            return .success(try parse(data: data))
        } catch let error as QuotaError {
            return .failure(error)
        } catch {
            return .failure(.decode("\(error)"))
        }
    }

    private struct Limit {
        var type: String
        var usedPercent: Double
        var windowSeconds: Int?
        var resetsAt: Date?
        var isMonthlyMarker: Bool
        var detail: String?
    }

    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("glm: not a json object")
        }
        if let success = root["success"] as? Bool, !success {
            let message = root["msg"] as? String ?? "request rejected"
            if QuotaJSON.int(root["code"]) == 401 { throw QuotaError.http(401, message) }
            throw QuotaError.decode("glm: \(message)")
        }
        guard let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [[String: Any]]
        else {
            throw QuotaError.decode("glm: missing data.limits")
        }

        let limits = rawLimits.compactMap { parseLimit($0, now: now) }
        let quotaLimits = limits
            .filter { $0.type == "TOKENS_LIMIT" || $0.type == "CREDIT_LIMIT" }
            .sorted { ($0.windowSeconds ?? Int.max) < ($1.windowSeconds ?? Int.max) }
        let timeLimit = limits.last { $0.type == "TIME_LIMIT" }

        let session = quotaLimits.count >= 2 ? quotaLimits.first : nil
        let longest = quotaLimits.last
        var primary: QuotaWindow?
        var secondary: QuotaWindow?
        if let session, let longest {
            primary = window(session, kind: kind(for: session, fallback: .fiveHour))
            secondary = window(longest, kind: kind(for: longest, fallback: .weekly))
        } else if let longest {
            primary = window(longest, kind: kind(for: longest, fallback: .fiveHour))
        }
        var extra: [QuotaWindow] = []
        if let timeLimit {
            let mcp = window(timeLimit, kind: .mcp)
            if primary == nil { primary = mcp } else { extra.append(mcp) }
        }
        guard primary != nil else {
            throw QuotaError.decode("glm: no usable limit entries")
        }

        let plan = ["planName", "plan", "plan_type", "packageName", "level"]
            .compactMap { payload[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return QuotaSnapshot(
            provider: .glm,
            primary: primary,
            secondary: secondary,
            extra: extra,
            planType: plan?.trimmingCharacters(in: .whitespaces),
            fetchedAt: now
        )
    }

    nonisolated private static func kind(for limit: Limit, fallback: QuotaWindowKind) -> QuotaWindowKind {
        guard let seconds = limit.windowSeconds else { return fallback }
        if seconds == 5 * 3600 { return .fiveHour }
        if seconds == 7 * 86400 { return .weekly }
        if seconds >= 28 * 86400 { return .monthly }
        return fallback
    }

    nonisolated private static func window(_ limit: Limit, kind: QuotaWindowKind) -> QuotaWindow {
        QuotaWindow(
            kind: kind,
            usedPercent: limit.usedPercent,
            resetsAt: limit.resetsAt,
            windowSeconds: limit.isMonthlyMarker ? nil : limit.windowSeconds,
            detail: limit.detail
        )
    }

    nonisolated private static func parseLimit(_ raw: [String: Any], now: Date) -> Limit? {
        guard let type = raw["type"] as? String,
              ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type),
              var percent = QuotaJSON.double(raw["percentage"])
        else { return nil }

        let usage = QuotaJSON.int(raw["usage"])
        let current = QuotaJSON.int(raw["currentValue"])
        let remaining = QuotaJSON.int(raw["remaining"])
        if let usage, usage > 0 {
            var used: Int?
            if let remaining {
                used = max(usage - remaining, current ?? (usage - remaining))
            } else if let current {
                used = current
            }
            if let used {
                percent = Double(max(0, min(usage, used))) / Double(usage) * 100
            }
        }
        percent = max(0, min(100, percent))

        let unit = QuotaJSON.int(raw["unit"]) ?? 0
        let number = QuotaJSON.int(raw["number"]) ?? 0
        let multipliers: [Int: Int] = [1: 86400, 3: 3600, 5: 60, 6: 7 * 86400]
        var windowSeconds: Int? = (number > 0 && multipliers[unit] != nil) ? number * multipliers[unit]! : nil
        let isMonthlyMarker = type == "TIME_LIMIT" && unit == 5 && number == 1
        if isMonthlyMarker { windowSeconds = 30 * 86400 }

        var resetsAt = QuotaJSON.epochMillis(raw["nextResetTime"])
        // A five-hour coding-plan reset cannot lie more than five hours away.
        if type != "TIME_LIMIT", windowSeconds == 5 * 3600, let reset = resetsAt,
           reset.timeIntervalSince(now) > 5 * 3600 + 60 {
            resetsAt = nil
        }

        var parts: [String] = []
        if let usage { parts.append("\(usage) limit") }
        if let remaining { parts.append("\(remaining) remaining") }

        return Limit(
            type: type,
            usedPercent: percent,
            windowSeconds: windowSeconds,
            resetsAt: resetsAt,
            isMonthlyMarker: isMonthlyMarker,
            detail: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }
}
