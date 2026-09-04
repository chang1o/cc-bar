import Foundation

/// Kimi Code quota: `GET {host}/coding/v1/usages` with the Kimi Code API key.
/// `usage` is the weekly request quota, `limits[0]` the 5-hour rate limit.
nonisolated enum KimiQuotaClient {
    nonisolated static let defaultBaseURL = URL(string: "https://api.kimi.com/coding/")!

    nonisolated static func usageURL(baseURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme ?? "https"
        components.host = baseURL.host
        components.port = baseURL.port
        components.path = "/coding/v1/usages"
        return components.url ?? URL(string: "https://api.kimi.com/coding/v1/usages")!
    }

    nonisolated static func fetch(apiKey: String, baseURL: URL) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: usageURL(baseURL: baseURL))
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

    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("kimi: not a json object")
        }
        guard let usage = root["usage"] as? [String: Any] else {
            throw QuotaError.decode("kimi: missing usage")
        }
        guard let weeklyWindow = window(detail: usage, windowSeconds: 7 * 24 * 60 * 60) else {
            throw QuotaError.decode("kimi: usage.limit missing")
        }
        let weekly = QuotaLimit.standard(kind: .weekly, window: weeklyWindow, displayName: "Weekly requests")

        var rateLimit: QuotaLimit?
        if let limits = root["limits"] as? [[String: Any]], let first = limits.first,
           let detail = first["detail"] as? [String: Any] {
            let seconds = windowSeconds(first["window"] as? [String: Any]) ?? 5 * 60 * 60
            if let rateWindow = window(detail: detail, windowSeconds: seconds) {
                rateLimit = .standard(
                    kind: QuotaSnapshot.kind(for: rateWindow, fallback: .fiveHour),
                    window: rateWindow,
                    displayName: "Rate limit"
                )
            }
        }

        return QuotaSnapshot(
            app: .kimi,
            primaryLimit: rateLimit ?? weekly,
            secondaryLimit: rateLimit == nil ? nil : weekly,
            planType: nil,
            fetchedAt: now
        )
    }

    nonisolated private static func window(detail: [String: Any], windowSeconds: Int?) -> QuotaWindow? {
        guard let limit = QuotaJSON.int(detail["limit"]), limit > 0 else { return nil }
        let used: Int
        if let raw = QuotaJSON.int(detail["used"]), raw >= 0 {
            used = raw
        } else if let remaining = QuotaJSON.int(detail["remaining"]), (0...limit).contains(remaining) {
            used = limit - remaining
        } else {
            used = 0
        }
        return QuotaWindow(
            usedPercent: Double(min(used, limit)) / Double(limit) * 100,
            resetsAt: QuotaJSON.isoDate(detail["resetTime"] ?? detail["reset_time"] ?? detail["resetAt"]),
            windowSeconds: windowSeconds,
            detail: "\(used)/\(limit) requests"
        )
    }

    nonisolated private static func windowSeconds(_ window: [String: Any]?) -> Int? {
        guard let window, let duration = QuotaJSON.int(window["duration"]), duration > 0 else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3600
        case "TIME_UNIT_DAY": return duration * 86400
        default: return nil
        }
    }
}
