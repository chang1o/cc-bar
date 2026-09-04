import Foundation

enum ClaudeCLIFallbackQuotaClient {
    nonisolated static func fetch(timeout: TimeInterval = 20) async -> Result<QuotaSnapshot, QuotaError> {
        await Task.detached(priority: .utility) {
            run(timeout: timeout)
        }.value
    }

    nonisolated private static func run(timeout: TimeInterval) -> Result<QuotaSnapshot, QuotaError> {
        let command = claudeCommand()
        let attempts: [(String, [String])] = [
            ("/usr/bin/script", ["-q", "/dev/null"] + command),
            (command[0], Array(command.dropFirst()))
        ]

        var lastError: QuotaError = .transport("claude cli not available")
        for attempt in attempts {
            guard FileManager.default.isExecutableFile(atPath: attempt.0) else { continue }
            switch runProcess(executable: attempt.0, arguments: attempt.1, timeout: timeout) {
            case .success(let text):
                switch parse(text: text) {
                case .success(let snapshot):
                    return .success(snapshot)
                case .failure(let error):
                    lastError = error
                }
            case .failure(let error):
                lastError = error
            }
        }
        return .failure(lastError)
    }

    nonisolated private static func claudeCommand() -> [String] {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return [path]
        }
        return ["/usr/bin/env", "claude"]
    }

    nonisolated private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Result<String, QuotaError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            return .failure(.transport("claude cli launch failed: \(error)"))
        }

        let commands = "/usage\n\n/status\n/exit\n"
        if let data = commands.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        stdin.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            return .failure(.transport("claude cli fallback timed out"))
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = [
            String(data: out, encoding: .utf8),
            String(data: err, encoding: .utf8)
        ].compactMap { $0 }.joined(separator: "\n")

        guard proc.terminationStatus == 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.transport("claude cli exited \(proc.terminationStatus)"))
        }
        return .success(text)
    }

    nonisolated private static func parse(text: String) -> Result<QuotaSnapshot, QuotaError> {
        let clean = stripANSICodes(text)
        let lower = clean.lowercased()
        let compact = lower.filter { !$0.isWhitespace }

        if lower.contains("rate limited") || lower.contains("rate_limit_error") || compact.contains("ratelimited") {
            return .failure(.http(429, "claude cli usage endpoint is rate limited"))
        }
        if lower.contains("authentication_error") || lower.contains("token_expired") {
            return .failure(.http(401, "claude cli authentication failed"))
        }
        if lower.contains("failed to load usage data") || compact.contains("failedtoloadusagedata") {
            return .failure(.decode("claude cli could not load usage data"))
        }

        let sessionLeft = extractPercent(after: ["Current session"], in: clean)
        let weeklyLeft = extractPercent(after: ["Current week (all models)", "Current week"], in: clean)
        let sonnetLeft = extractPercent(after: ["Current week (Sonnet only)", "Current week (Sonnet)"], in: clean)
        let opusLeft = extractPercent(after: ["Current week (Opus)"], in: clean)

        guard let sessionLeft else {
            return .failure(.decode("claude cli usage output missing Current session"))
        }

        return .success(QuotaSnapshot(
            provider: .claude,
            primary: makeWindow(kind: .fiveHour,
                                percentLeft: sessionLeft,
                                resetText: extractReset(after: ["Current session"], in: clean)),
            secondary: makeWindow(kind: .weekly,
                                  percentLeft: weeklyLeft,
                                  resetText: extractReset(after: ["Current week (all models)", "Current week"], in: clean)),
            extra: [
                makeWindow(kind: .weeklyOpus,
                           percentLeft: opusLeft,
                           resetText: extractReset(after: ["Current week (Opus)"], in: clean)),
                makeWindow(kind: .weeklySonnet,
                           percentLeft: sonnetLeft,
                           resetText: extractReset(after: ["Current week (Sonnet only)", "Current week (Sonnet)"], in: clean))
            ].compactMap { $0 },
            planType: nil,
            fetchedAt: Date()
        ))
    }

    nonisolated private static func makeWindow(
        kind: QuotaWindowKind,
        percentLeft: Int?,
        resetText: String?
    ) -> QuotaWindow? {
        guard let percentLeft else { return nil }
        return QuotaWindow(
            kind: kind,
            usedPercent: max(0, min(100, 100 - Double(percentLeft))),
            resetsAt: parseResetDate(resetText),
            windowSeconds: kind.defaultSeconds
        )
    }

    nonisolated private static func extractPercent(after labels: [String], in text: String) -> Int? {
        let lines = text.components(separatedBy: .newlines)
        let normalizedLines = lines.map(normalizedForLabelSearch)
        for label in labels.map(normalizedForLabelSearch) {
            for (idx, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
                for candidate in lines.dropFirst(idx).prefix(12) {
                    if let pct = percentFromLine(candidate) { return pct }
                }
            }
        }

        let compact = normalizedForLabelSearch(text)
        guard labels.contains(where: { compact.contains(normalizedForLabelSearch($0)) }) else { return nil }
        return allPercents(text).first
    }

    nonisolated private static func percentFromLine(_ line: String) -> Int? {
        guard !line.contains("|") else { return nil }
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\p{Zs}*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              let valRange = Range(match.range(at: 1), in: line),
              let rawVal = Double(line[valRange])
        else { return nil }

        let clamped = max(0, min(100, rawVal))
        let lower = line.lowercased()
        if ["used", "spent", "consumed"].contains(where: lower.contains) {
            return Int((100 - clamped).rounded())
        }
        if ["left", "remaining", "available"].contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return nil
    }

    nonisolated private static func allPercents(_ text: String) -> [Int] {
        let normalized = text.lowercased().filter { !$0.isWhitespace }
        guard normalized.contains("currentsession") || normalized.contains("currentweek") else { return [] }
        guard normalized.contains("used") || normalized.contains("left")
            || normalized.contains("remaining") || normalized.contains("available")
        else { return [] }
        return text.components(separatedBy: .newlines).compactMap(percentFromLine)
    }

    nonisolated private static func extractReset(after labels: [String], in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let normalizedLines = lines.map(normalizedForLabelSearch)
        for label in labels.map(normalizedForLabelSearch) {
            for (idx, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
                for candidate in lines.dropFirst(idx).prefix(14) {
                    if let range = candidate.range(of: "Resets", options: [.caseInsensitive]) {
                        return String(candidate[range.lowerBound...])
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n)"))
                    }
                }
            }
        }
        return nil
    }

    nonisolated private static func parseResetDate(_ text: String?) -> Date? {
        guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = Date()

        for format in ["MMM d, h:mma", "MMM d h:mma", "MMM d, h:mm a", "MMM d h:mm a", "h:mma", "h:mm a", "HH:mm", "H:mm"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: raw) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = formatter.timeZone
            let now = Date()
            if format.contains("MMM") {
                var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
                comps.year = calendar.component(.year, from: now)
                return calendar.date(from: comps)
            }
            let comps = calendar.dateComponents([.hour, .minute], from: parsed)
            guard let anchored = calendar.date(
                bySettingHour: comps.hour ?? 0,
                minute: comps.minute ?? 0,
                second: 0,
                of: now
            ) else { return nil }
            return anchored >= now ? anchored : calendar.date(byAdding: .day, value: 1, to: anchored)
        }
        return nil
    }

    nonisolated private static func stripANSICodes(_ text: String) -> String {
        let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    nonisolated private static func normalizedForLabelSearch(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}
