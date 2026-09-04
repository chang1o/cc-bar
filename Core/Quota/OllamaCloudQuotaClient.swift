import Foundation

/// Ollama Cloud identity and usage through the same signed API the Ollama desktop app uses:
/// `POST /api/me` for the account, `GET /api/usage` for the plan limits. The local
/// `~/.ollama/id_ed25519` key signs each request; ccpm profiles use a Bearer API key.
nonisolated enum OllamaCloudQuotaClient {
    nonisolated static let baseURL = URL(string: "https://ollama.com")!

    enum Credential: Sendable {
        case localKey(OllamaLocalKey)
        case apiKey(String)
    }

    struct Identity: Sendable, Equatable {
        var name: String?
        var email: String?
        var plan: String?

        var accountKey: String? { email?.lowercased() ?? name }
    }

    nonisolated static func fetchIdentity(_ credential: Credential) async -> Result<Identity, QuotaError> {
        await request(credential, method: "POST", path: "/api/me").flatMap { data in
            do { return .success(try parseIdentity(data: data)) }
            catch let error as QuotaError { return .failure(error) }
            catch { return .failure(.decode("\(error)")) }
        }
    }

    nonisolated static func fetchUsage(
        _ credential: Credential,
        planType: String?,
        now: Date = Date()
    ) async -> Result<QuotaSnapshot, QuotaError> {
        await request(credential, method: "GET", path: "/api/usage").flatMap { data in
            do { return .success(try parseUsage(data: data, planType: planType, now: now)) }
            catch let error as QuotaError { return .failure(error) }
            catch { return .failure(.decode("\(error)")) }
        }
    }

    // MARK: - Transport

    nonisolated private static func request(
        _ credential: Credential,
        method: String,
        path: String
    ) async -> Result<Data, QuotaError> {
        let ts = String(Int(Date().timeIntervalSince1970))
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        let authorization: String
        switch credential {
        case .localKey(let key):
            components.queryItems = [URLQueryItem(name: "ts", value: ts)]
            do { authorization = try key.authorization(method: method, path: path, ts: ts) }
            catch { return .failure(.tokenRefreshFailed("ollama key signing failed: \(error)")) }
        case .apiKey(let apiKey):
            authorization = "Bearer \(apiKey)"
        }
        guard let url = components.url else { return .failure(.transport("ollama: bad url")) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.http(http.statusCode, "ollama: not signed in (run `ollama signin`)"))
            }
            return .failure(.http(http.statusCode, String(data: data, encoding: .utf8) ?? ""))
        }
        return .success(data)
    }

    // MARK: - Parsing

    /// `/api/me` answers with capitalised keys from ollama.com and lowercase ones through the
    /// local server proxy; both are accepted.
    nonisolated static func parseIdentity(data: Data) throws -> Identity {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("ollama: /api/me is not a json object")
        }
        let lowered = Dictionary(uniqueKeysWithValues: root.map { ($0.key.lowercased(), $0.value) })
        func text(_ key: String) -> String? {
            guard let value = lowered[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let identity = Identity(name: text("name"), email: text("email"), plan: text("plan"))
        guard identity.name != nil || identity.email != nil else {
            throw QuotaError.decode("ollama: /api/me has no name or email")
        }
        return identity
    }

    /// `limits` is keyed by window name; each entry carries `usage` as a fraction (0.108 =
    /// 10.8 % used) and the per-model request counts of that window.
    nonisolated static func parseUsage(data: Data, planType: String?, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("ollama: /api/usage is not a json object")
        }
        guard let limits = root["limits"] as? [String: Any] else {
            throw QuotaError.decode("ollama: missing limits")
        }
        var lanes: [QuotaLimit] = []
        for (rawKey, rawValue) in limits {
            guard let block = rawValue as? [String: Any], let fraction = QuotaJSON.double(block["usage"]) else { continue }
            let key = rawKey.lowercased()
            let window = QuotaWindow(
                usedPercent: max(0, min(100, fraction * 100)),
                resetsAt: QuotaJSON.isoDate(block["resets_at"] ?? block["reset_at"] ?? block["ends_at"]),
                windowSeconds: nil,
                detail: requestsDetail(block["models"])
            )
            switch key {
            case "monthly":
                lanes.append(QuotaLimit(id: "monthly", kind: .unknown, displayName: "Monthly", window: window, isActive: nil))
            case "weekly":
                lanes.append(QuotaLimit.standard(kind: .weekly, window: window))
            case "hourly", "five_hour", "session":
                lanes.append(QuotaLimit.standard(kind: .fiveHour, window: window))
            default:
                lanes.append(QuotaLimit(id: key, kind: .unknown, displayName: rawKey.capitalized, window: window, isActive: nil))
            }
        }
        guard !lanes.isEmpty else {
            throw QuotaError.decode("ollama: limits has no usage entries")
        }
        // Stable order: monthly (the plan allowance) first, then shorter windows.
        let rank: (QuotaLimit) -> Int = { limit in
            switch limit.id {
            case "monthly": return 0
            case "weekly": return 1
            case "five-hour": return 2
            default: return 3
            }
        }
        lanes.sort { (rank($0), $0.id) < (rank($1), $1.id) }

        return QuotaSnapshot(
            app: .ollama,
            primaryLimit: lanes[0],
            secondaryLimit: lanes.count > 1 ? lanes[1] : nil,
            auxiliaryLimits: Array(lanes.dropFirst(2)),
            planType: planType,
            fetchedAt: now
        )
    }

    nonisolated private static func requestsDetail(_ models: Any?) -> String? {
        guard let models = models as? [[String: Any]] else { return nil }
        let total = models.compactMap { QuotaJSON.int($0["request_count"]) }.reduce(0, +)
        guard total > 0 else { return nil }
        return "\(total) requests"
    }
}
