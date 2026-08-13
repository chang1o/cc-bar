import Foundation

enum AntigravityQuotaClient {
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var account: AntigravityAccount
    }

    fileprivate struct ProcessInfo: Sendable {
        enum Kind: Int, Sendable {
            case app = 0
            case ide = 1
        }

        var pid: Int32
        var csrfToken: String
        var kind: Kind
    }

    struct Discovery: Sendable {
        fileprivate var isInstalled: Bool
        fileprivate var processes: [ProcessInfo]
        fileprivate var processError: String?

        var availability: AntigravityAvailability {
            guard isInstalled else { return .notInstalled }
            if processError != nil {
                return .unavailable("无法检查 Antigravity 进程")
            }
            return processes.isEmpty ? .installed : .running
        }
    }

    private struct CommandResult: Sendable {
        var status: Int32
        var stdout: String
    }

    private static let quotaSummaryPath =
        "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath =
        "/exa.language_server_pb.LanguageServerService/GetUserStatus"

    nonisolated static func detectAvailability() async -> AntigravityAvailability {
        let discovery = await discover()
        return discovery.availability
    }

    /// 单轮取得安装状态与进程信息，供 availability 和 fetch 复用，避免重复执行 ps。
    nonisolated static func discover() async -> Discovery {
        let installed = installedApplicationURLs().contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard installed else {
            return Discovery(isInstalled: false, processes: [], processError: nil)
        }
        do {
            return Discovery(
                isInstalled: true,
                processes: try processInfos(),
                processError: nil
            )
        } catch {
            return Discovery(
                isInstalled: true,
                processes: [],
                processError: sanitizedMessage(error)
            )
        }
    }

    nonisolated static func fetch() async -> Result<Fetched, QuotaError> {
        let discovery = await discover()
        return await fetch(discovery: discovery)
    }

    nonisolated static func fetch(discovery: Discovery) async -> Result<Fetched, QuotaError> {
        do {
            if let processError = discovery.processError {
                return .failure(.transport(processError))
            }
            let processes = discovery.processes
            guard !processes.isEmpty else {
                return .failure(.transport("Antigravity 未运行"))
            }

            var lastMessage = "未找到可用的本地额度接口"
            for process in processes {
                let ports: [Int]
                do {
                    ports = try listeningPorts(pid: process.pid)
                } catch {
                    lastMessage = "Antigravity 本地端口不可用"
                    continue
                }

                var processFallback: Fetched?
                for port in ports {
                    do {
                        if let snapshot = try await fetchQuotaSummary(
                            port: port,
                            csrfToken: process.csrfToken
                        ) {
                            let identity = try? await fetchUserStatus(
                                port: port,
                                csrfToken: process.csrfToken
                            )
                            let merged = QuotaSnapshot(
                                app: .antigravity,
                                primaryLimit: snapshot.primaryLimit,
                                secondaryLimit: snapshot.secondaryLimit,
                                modelLimits: snapshot.modelLimits,
                                geminiWindow: snapshot.geminiWindow,
                                geminiWeekly: snapshot.geminiWeekly,
                                planType: identity?.account.planType,
                                fetchedAt: snapshot.fetchedAt
                            )
                            return .success(Fetched(
                                snapshot: merged,
                                account: identity?.account ?? AntigravityAccount()
                            ))
                        }

                        if processFallback == nil,
                           let fallback = try await fetchUserStatus(
                            port: port,
                            csrfToken: process.csrfToken
                           ),
                           fallback.snapshot.primaryLimit != nil
                        {
                            processFallback = fallback
                        }
                    } catch {
                        lastMessage = sanitizedMessage(error)
                    }
                }
                if let processFallback {
                    return .success(processFallback)
                }
            }
            return .failure(.transport(lastMessage))
        } catch {
            return .failure(.transport(sanitizedMessage(error)))
        }
    }

    // MARK: - Process and port discovery

    nonisolated private static func installedApplicationURLs() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            URL(fileURLWithPath: "/Applications/Antigravity IDE.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Antigravity.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Antigravity IDE.app"),
        ]
    }

    nonisolated private static func processInfos() throws -> [ProcessInfo] {
        let result = try run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        )
        guard result.status == 0 else { throw LocalError.processLookup }

        var matches: [ProcessInfo] = []
        for line in result.stdout.split(separator: "\n") {
            let text = String(line)
            guard text.localizedCaseInsensitiveContains("language_server")
                    || text.localizedCaseInsensitiveContains("language-server")
            else { continue }

            let kind: ProcessInfo.Kind?
            if text.contains("/Antigravity.app/")
                || (text.contains("--app_data_dir antigravity")
                    && !text.contains("--app_data_dir antigravity-ide"))
            {
                kind = .app
            } else if text.contains("/Antigravity IDE.app/")
                        || text.contains("--app_data_dir antigravity-ide")
            {
                kind = .ide
            } else {
                kind = nil
            }
            guard let kind,
                  let pid = leadingPID(in: text),
                  let token = flagValue("--csrf_token", in: text),
                  !token.isEmpty
            else { continue }
            matches.append(ProcessInfo(pid: pid, csrfToken: token, kind: kind))
        }
        return matches.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.pid < $1.pid
        }
    }

    nonisolated private static func listeningPorts(pid: Int32) throws -> [Int] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw LocalError.missingLSOF
        }
        let result = try run(
            executable: executable,
            arguments: [
                "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid),
            ]
        )
        guard result.status == 0 else { throw LocalError.noListeningPorts }

        let regex = try NSRegularExpression(pattern: #"127\.0\.0\.1:(\d+)\s+\(LISTEN\)"#)
        let range = NSRange(result.stdout.startIndex..., in: result.stdout)
        let ports = regex.matches(in: result.stdout, range: range).compactMap { match -> Int? in
            guard let swiftRange = Range(match.range(at: 1), in: result.stdout) else { return nil }
            return Int(result.stdout[swiftRange])
        }
        let unique = Array(Set(ports)).sorted()
        guard !unique.isEmpty else { throw LocalError.noListeningPorts }
        return unique
    }

    nonisolated private static func run(
        executable: String,
        arguments: [String]
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }

    nonisolated private static func leadingPID(in line: String) -> Int32? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let token = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        return Int32(token)
    }

    nonisolated private static func flagValue(_ flag: String, in command: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|\s)"# + escaped + #"(?:=|\s+)([^\s]+)"#
        ) else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              let swiftRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[swiftRange])
    }

    // MARK: - Local API

    nonisolated private static func fetchQuotaSummary(
        port: Int,
        csrfToken: String
    ) async throws -> QuotaSnapshot? {
        let data = try await request(
            port: port,
            path: quotaSummaryPath,
            csrfToken: csrfToken,
            body: ["forceRefresh": true]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalError.invalidResponse
        }
        let payload = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        guard let groups = payload["groups"] as? [[String: Any]] else {
            return nil
        }

        let fetchedAt = Date()

        // --- Claude + GPT group ---
        let cgGroup = groups.first(where: {
            let name = ($0["displayName"] as? String ?? "").lowercased()
            return name.contains("claude") && name.contains("gpt")
        })
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        if let group = cgGroup {
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(in: bucket)
                else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let name = (bucket["displayName"] as? String ?? "").lowercased()
                let description = bucket["description"] as? String
                let reset = resetDate(
                    value: bucket["resetTime"],
                    description: description,
                    relativeTo: fetchedAt
                )
                let window = QuotaWindow(
                    usedPercent: max(0, min(100, 100 - remaining * 100)),
                    resetsAt: reset,
                    windowSeconds: nil
                )
                if id.contains("week") || name.contains("week") {
                    weekly = window
                } else if id.contains("five") || id.contains("session")
                            || name.contains("five") || name.contains("5")
                {
                    fiveHour = window
                }
            }
        }

        // --- Gemini group ---
        let geminiGroup = groups.first(where: {
            let name = ($0["displayName"] as? String ?? "").lowercased()
            return name.contains("gemini")
        })
        var geminiWindow: QuotaWindow?
        var geminiWeekly: QuotaWindow?
        if let group = geminiGroup {
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            for bucket in buckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = remainingFraction(in: bucket)
                else { continue }
                let id = (bucket["bucketId"] as? String ?? "").lowercased()
                let description = bucket["description"] as? String
                let reset = resetDate(
                    value: bucket["resetTime"],
                    description: description,
                    relativeTo: fetchedAt
                )
                let window = QuotaWindow(
                    usedPercent: max(0, min(100, 100 - remaining * 100)),
                    resetsAt: reset,
                    windowSeconds: nil
                )
                if id.contains("week") {
                    geminiWeekly = window
                } else if id.contains("5h") || id.contains("five") || id.contains("session") {
                    geminiWindow = window
                }
            }
        }

        guard fiveHour != nil || weekly != nil else { return nil }
        return QuotaSnapshot(
            app: .antigravity,
            primaryLimit: fiveHour.map { .standard(kind: .fiveHour, window: $0) }
                ?? weekly.map { .standard(kind: .weekly, window: $0) },
            secondaryLimit: fiveHour == nil ? nil : weekly.map {
                .standard(kind: .weekly, window: $0)
            },
            geminiWindow: geminiWindow,
            geminiWeekly: geminiWeekly,
            planType: nil,
            fetchedAt: fetchedAt
        )
    }

    nonisolated private static func fetchUserStatus(
        port: Int,
        csrfToken: String
    ) async throws -> Fetched? {
        let data = try await request(
            port: port,
            path: userStatusPath,
            csrfToken: csrfToken,
            body: [
                "metadata": [
                    "ideName": "antigravity",
                    "extensionName": "antigravity",
                    "ideVersion": "unknown",
                    "locale": "en",
                ],
            ]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any]
        else {
            throw LocalError.invalidResponse
        }
        let account = AntigravityAccount(
            email: status["email"] as? String,
            planType: planName(in: status)
        )

        let configData = status["cascadeModelConfigData"] as? [String: Any]
        let configs = configData?["clientModelConfigs"] as? [[String: Any]] ?? []

        // Claude + GPT configs
        let cgCandidates: [(Double, Date?)] = configs.compactMap { config in
            let label = (config["label"] as? String ?? "").lowercased()
            guard label.contains("claude") || label.contains("gpt"),
                  let quota = config["quotaInfo"] as? [String: Any],
                  let remaining = number(quota["remainingFraction"])
            else { return nil }
            return (
                remaining,
                resetDate(value: quota["resetTime"], description: nil, relativeTo: Date())
            )
        }
        let cgRepresentative = cgCandidates.min { $0.0 < $1.0 }
        let fiveHour = cgRepresentative.map {
            QuotaWindow(
                usedPercent: max(0, min(100, 100 - $0.0 * 100)),
                resetsAt: $0.1,
                windowSeconds: 5 * 60 * 60
            )
        }

        // Gemini configs
        let geminiCandidates: [(Double, Date?)] = configs.compactMap { config in
            let label = (config["label"] as? String ?? "").lowercased()
            guard label.contains("gemini"),
                  let quota = config["quotaInfo"] as? [String: Any],
                  let remaining = number(quota["remainingFraction"])
            else { return nil }
            return (
                remaining,
                resetDate(value: quota["resetTime"], description: nil, relativeTo: Date())
            )
        }
        let geminiRepresentative = geminiCandidates.min { $0.0 < $1.0 }
        let geminiWindow = geminiRepresentative.map {
            QuotaWindow(
                usedPercent: max(0, min(100, 100 - $0.0 * 100)),
                resetsAt: $0.1,
                windowSeconds: 5 * 60 * 60
            )
        }

        let snapshot = QuotaSnapshot(
            app: .antigravity,
            primaryLimit: fiveHour.map { .standard(kind: .fiveHour, window: $0) },
            secondaryLimit: nil,
            geminiWindow: geminiWindow,
            geminiWeekly: nil,
            planType: account.planType,
            fetchedAt: Date()
        )
        return Fetched(snapshot: snapshot, account: account)
    }

    nonisolated private static func request(
        port: Int,
        path: String,
        csrfToken: String,
        body: [String: Any]
    ) async throws -> Data {
        guard (1...65535).contains(port),
              let url = URL(string: "https://127.0.0.1:\(port)\(path)")
        else {
            throw LocalError.invalidURL
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        let delegate = AntigravityLoopbackSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw LocalError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Parsing helpers

    nonisolated private static func remainingFraction(in bucket: [String: Any]) -> Double? {
        if let direct = number(bucket["remainingFraction"]) { return direct }
        if let remaining = bucket["remaining"] as? [String: Any] {
            return number(remaining["remainingFraction"]) ?? number(remaining["value"])
        }
        return nil
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    nonisolated private static func planName(in status: [String: Any]) -> String? {
        if let tier = status["userTier"] as? [String: Any],
           let name = nonEmpty(tier["name"] as? String)
        {
            return name
        }
        guard let planStatus = status["planStatus"] as? [String: Any],
              let info = planStatus["planInfo"] as? [String: Any]
        else { return nil }
        for key in ["planDisplayName", "displayName", "productName", "planName", "planShortName"] {
            if let name = nonEmpty(info[key] as? String) { return name }
        }
        return nil
    }

    nonisolated private static func resetDate(
        value: Any?,
        description: String?,
        relativeTo now: Date
    ) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            if let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let description else { return nil }
        let days = countdownValue(unit: "day", in: description)
        let hours = countdownValue(unit: "hour", in: description)
        let minutes = countdownValue(unit: "minute", in: description)
        let seconds = days * 86400 + hours * 3600 + minutes * 60
        return seconds > 0 ? now.addingTimeInterval(TimeInterval(seconds)) : nil
    }

    nonisolated private static func countdownValue(unit: String, in text: String) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: unit)
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d+)\s+"# + escaped + #"s?"#,
            options: [.caseInsensitive]
        ) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text)
        else { return 0 }
        return Int(text[swiftRange]) ?? 0
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    nonisolated private static func sanitizedMessage(_ error: Error) -> String {
        switch error {
        case LocalError.http(let status):
            return "Antigravity 本地接口返回 HTTP \(status)"
        case LocalError.missingLSOF:
            return "未找到 lsof，无法发现 Antigravity 本地端口"
        case LocalError.noListeningPorts:
            return "Antigravity 正在启动，本地端口尚未就绪"
        case LocalError.processLookup:
            return "无法检查 Antigravity 进程"
        default:
            return "Antigravity 本地额度查询失败"
        }
    }

    private enum LocalError: Error {
        case processLookup
        case missingLSOF
        case noListeningPorts
        case invalidURL
        case invalidResponse
        case http(Int)
    }
}

private final class AntigravityLoopbackSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1",
              space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
