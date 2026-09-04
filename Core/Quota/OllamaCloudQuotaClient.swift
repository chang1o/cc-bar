import Foundation

/// Ollama Cloud exposes no quota API; the numbers live on the signed-in
/// settings page. We fetch it with a user-pasted `Cookie:` header and parse
/// the "Included usage" / "Monthly usage" / "Weekly usage" blocks.
nonisolated enum OllamaCloudQuotaClient {
    nonisolated static let settingsURL = URL(string: "https://ollama.com/settings")!

    nonisolated static func fetch(cookieHeader: String) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: settingsURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://ollama.com", forHTTPHeaderField: "Origin")
        request.setValue(settingsURL.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
        if isSignInRedirect(http.url) {
            return .failure(.http(401, "ollama session expired; paste a fresh cookie"))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.http(http.statusCode, "ollama session rejected; paste a fresh cookie"))
            }
            return .failure(.http(http.statusCode, ""))
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        do {
            return .success(try parse(html: html))
        } catch let error as QuotaError {
            return .failure(error)
        } catch {
            return .failure(.decode("\(error)"))
        }
    }

    nonisolated static func isSignInRedirect(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""
        return path.contains("signin") || path.contains("login") || host.contains("authkit")
    }

    private static let monthlyLabel = "Monthly usage"
    private static let legacyPrimaryLabels = ["Session usage", "Hourly usage"]
    private static let weeklyLabel = "Weekly usage"
    private static var allLabels: [String] { [monthlyLabel] + legacyPrimaryLabels + [weeklyLabel] }

    nonisolated static func parse(html: String, now: Date = Date()) throws -> QuotaSnapshot {
        let monthly = usageBlock(labels: [monthlyLabel], html: html)
        let session = usageBlock(labels: legacyPrimaryLabels, html: html)
        let weekly = usageBlock(labels: [weeklyLabel], html: html)

        if monthly == nil, session == nil, weekly == nil {
            if looksSignedOut(html) {
                throw QuotaError.http(401, "ollama session expired; paste a fresh cookie")
            }
            throw QuotaError.decode("ollama: usage blocks not found on settings page")
        }

        let monthlyWindow = monthly.map {
            QuotaWindow(kind: .monthly, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowSeconds: nil, detail: $0.detail)
        }
        let sessionWindow = session.map {
            QuotaWindow(kind: .fiveHour, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowSeconds: 5 * 3600, detail: nil)
        }
        let weeklyWindow = weekly.map {
            QuotaWindow(kind: .weekly, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, windowSeconds: 7 * 86400, detail: nil)
        }

        var extra: [QuotaWindow] = []
        let primary: QuotaWindow?
        if let monthlyWindow {
            primary = monthlyWindow
            if let sessionWindow { extra.append(sessionWindow) }
        } else {
            primary = sessionWindow
        }

        return QuotaSnapshot(
            provider: .ollama,
            primary: primary,
            secondary: weeklyWindow,
            extra: extra,
            planType: planName(html),
            fetchedAt: now
        )
    }

    private struct Block {
        var usedPercent: Double
        var resetsAt: Date?
        var detail: String?
    }

    nonisolated private static func usageBlock(labels: [String], html: String) -> Block? {
        for label in labels {
            guard let range = html.range(of: label) else { continue }
            let tail = String(html[range.upperBound...])
            let boundary = allLabels
                .filter { $0 != label }
                .compactMap { tail.range(of: $0)?.lowerBound }
                .min()
            let window = String((boundary.map { String(tail[..<$0]) } ?? tail).prefix(4000))
            guard let percent = percent(in: window) else { continue }
            return Block(usedPercent: percent.value, resetsAt: isoDate(in: window), detail: percent.detail)
        }
        return nil
    }

    nonisolated private static func percent(in text: String) -> (value: Double, detail: String?)? {
        if let raw = firstCapture(in: text, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, options: [.caseInsensitive]),
           let value = Double(raw) {
            return (value, nil)
        }
        let amount = #"((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
        if let regex = try? NSRegularExpression(pattern: #"\$\#(amount)\s+of\s+\$\#(amount)\s+used"#, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 2,
               let usedRange = Range(match.range(at: 1), in: text),
               let limitRange = Range(match.range(at: 2), in: text),
               let used = Double(text[usedRange].replacingOccurrences(of: ",", with: "")),
               let limit = Double(text[limitRange].replacingOccurrences(of: ",", with: "")),
               limit > 0 {
                return (used / limit * 100, "$\(text[usedRange]) of $\(text[limitRange])")
            }
        }
        if let raw = firstCapture(in: text, pattern: #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#, options: [.caseInsensitive]),
           let value = Double(raw) {
            return (value, nil)
        }
        return nil
    }

    nonisolated private static func isoDate(in text: String) -> Date? {
        guard let raw = firstCapture(in: text, pattern: #"data-time=\"([^\"]+)\""#, options: []) else { return nil }
        return QuotaJSON.isoDate(raw)
    }

    nonisolated private static func planName(_ html: String) -> String? {
        let patterns = [
            #"Included usage\s*</span>\s*<span[^>]*>([^<]+)</span"#,
            #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    nonisolated static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        let hasSignInHeading = lower.contains("sign in to ollama") || lower.contains("log in to ollama")
        let hasAuthEndpoint = lower.contains("/api/auth/signin") || lower.contains("/auth/signin")
            || lower.contains("action=\"/login\"") || lower.contains("href=\"/login\"")
            || lower.contains("action=\"/signin\"") || lower.contains("href=\"/signin\"")
        let hasPasswordField = lower.contains("type=\"password\"") || lower.contains("name=\"password\"")
        let hasEmailField = lower.contains("type=\"email\"") || lower.contains("name=\"email\"")
        let hasForm = lower.contains("<form")
        if hasSignInHeading, hasForm, hasEmailField || hasPasswordField || hasAuthEndpoint { return true }
        if hasForm, hasAuthEndpoint { return true }
        return hasForm && hasPasswordField && hasEmailField
    }

    nonisolated private static func firstCapture(in text: String, pattern: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }
}
