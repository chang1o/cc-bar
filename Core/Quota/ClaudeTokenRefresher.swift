import Foundation
import os

nonisolated enum ClaudeTokenRefresher {
    private static let log = Logger(subsystem: "com.cc-bar", category: "claude-refresh")
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// access_token 临期判定 skew。cc-bar 是只读监控,不需要太激进的提前刷新——
    /// 让出主动权给 Claude Code CLI / Desktop 等"重客户端",避免和它们争抢
    /// 一次性的 refresh_token。原值 300s 太激进,会频繁触发竞态;30s 已经足够
    /// 覆盖网络往返开销。
    nonisolated static let refreshSkew: TimeInterval = 30
    /// 若 credentials.json 在最近这么久内被改过,认为别的客户端刚完成刷新,
    /// 跳过自己发请求,直接重读存储里的最新值。
    static let politeMtimeWindow: TimeInterval = 10
    /// 软恢复时等待存储被外部更新的延时。
    static let softRecoveryDelay: TimeInterval = 1.0
    static let keychainService = "Claude Code-credentials"

    struct Refreshed: Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    /// 进程内的"被存储里偷读到的"凭据快照,只取我们关心的字段。
    struct StoredSnapshot: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    /// 若 access_token 已过期或临近过期则用 refresh_token 续期,并写回原存储位置。
    /// 返回当前可用的最新 access_token,并同步更新 account 内的 token / expiresAt。
    ///
    /// 关键设计:
    /// 1. 通过 `Coordinator` 进程内串行 + 去重刷新调用,避免菜单栏 / 悬浮窗 / Popover
    ///    三个入口同时往 OAuth 端点轮同一个 refresh_token。
    /// 2. 真正发请求前先 *重读存储*——如果其他客户端(CLI / Desktop / cc-switch /
    ///    codexbar) 刚刚把新 token 写进来,直接采用,不发请求。
    /// 3. 文件源会看 mtime 礼让窗口,刚被改过的就先重读不抢。
    /// 4. 服务端返回 `invalid_grant` 时做一次"软恢复":稍等再重读,若发现新值,
    ///    认为是别的客户端抢先成功,静默使用新 token,不向 UI 报错。
    nonisolated static func ensureFreshAccessToken(
        account: inout ClaudeAccount
    ) async -> Result<String, QuotaError> {
        guard let current = account.accessToken else {
            return .failure(.missingToken)
        }
        if !isExpired(expiresAt: account.expiresAt) {
            return .success(current)
        }
        guard let refreshToken = account.refreshToken, !refreshToken.isEmpty else {
            return .failure(.tokenRefreshFailed("no refresh_token"))
        }
        do {
            let r = try await Coordinator.shared.refresh(
                source: account.source,
                currentRefresh: refreshToken
            )
            account.accessToken = r.accessToken
            account.refreshToken = r.refreshToken
            account.expiresAt = r.expiresAt
            account.expiredGuess = false
            return .success(r.accessToken)
        } catch let err as QuotaError {
            return .failure(err)
        } catch {
            return .failure(.tokenRefreshFailed("\(error)"))
        }
    }

    nonisolated static func isExpired(expiresAt: Date?, skew: TimeInterval = refreshSkew) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < skew
    }

    // MARK: - Coordinator

    /// 进程内串行化 + 去重的刷新协调器。
    private actor Coordinator {
        static let shared = Coordinator()
        private var inFlight: Task<Refreshed, Error>?

        /// 同源刷新合并:若已有刷新在飞行中,所有调用者共享同一结果,
        /// 避免一个进程内多个入口几乎同时拿同一个 refresh_token 各发一次请求。
        func refresh(source: CredentialSource, currentRefresh: String) async throws -> Refreshed {
            if let task = inFlight {
                return try await task.value
            }
            let task = Task {
                try await Coordinator.performRefresh(
                    source: source,
                    initialRefresh: currentRefresh
                )
            }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }

        /// 真正的刷新主流程。
        private static func performRefresh(
            source: CredentialSource,
            initialRefresh: String
        ) async throws -> Refreshed {
            var refreshToken = initialRefresh

            // 1) 拿锁后先 *重读* 一次存储:别人(CLI / Desktop / cc-switch)
            //    可能在我们排队等锁时已经刷新过并写回了新值。
            if let onDisk = ClaudeTokenRefresher.peekStored(source: source) {
                if let storedExpiresAt = onDisk.expiresAt,
                   !ClaudeTokenRefresher.isExpired(expiresAt: storedExpiresAt) {
                    // 存储里的 access_token 已经新鲜,直接用,不发请求。
                    return Refreshed(
                        accessToken: onDisk.accessToken,
                        refreshToken: onDisk.refreshToken ?? refreshToken,
                        expiresAt: storedExpiresAt
                    )
                }
                if let onDiskRefresh = onDisk.refreshToken, !onDiskRefresh.isEmpty {
                    // 即便 access_token 仍过期,也优先用存储里的最新 refresh_token,
                    // 否则我们手里这份很可能已经被旋转作废了。
                    refreshToken = onDiskRefresh
                }
            }

            // 2) 文件源:若文件刚被改过,礼让一拍再重读;依然过期才自己刷。
            if source == .file, ClaudeTokenRefresher.fileMtimeWithinPoliteWindow() {
                try? await Task.sleep(
                    nanoseconds: UInt64(ClaudeTokenRefresher.softRecoveryDelay * 1_000_000_000)
                )
                if let onDisk = ClaudeTokenRefresher.peekStored(source: source) {
                    if let storedExpiresAt = onDisk.expiresAt,
                       !ClaudeTokenRefresher.isExpired(expiresAt: storedExpiresAt) {
                        return Refreshed(
                            accessToken: onDisk.accessToken,
                            refreshToken: onDisk.refreshToken ?? refreshToken,
                            expiresAt: storedExpiresAt
                        )
                    }
                    if let onDiskRefresh = onDisk.refreshToken, !onDiskRefresh.isEmpty {
                        refreshToken = onDiskRefresh
                    }
                }
            }

            // 3) 真正发刷新请求。
            do {
                let refreshed = try await ClaudeTokenRefresher.performNetworkRefresh(
                    using: refreshToken
                )
                try ClaudeTokenRefresher.writeBack(source: source, refreshed: refreshed)
                return refreshed
            } catch QuotaError.tokenRevoked {
                // 4) 软恢复:别人可能就在这几百毫秒里抢先用旧 refresh_token 刷成功,
                //    服务端因此把我们这份判作 invalid_grant。
                //    稍等一拍重读存储,如果发现新值就静默采用,不报错。
                try? await Task.sleep(
                    nanoseconds: UInt64(ClaudeTokenRefresher.softRecoveryDelay * 1_000_000_000)
                )
                if let onDisk = ClaudeTokenRefresher.peekStored(source: source),
                   let onDiskRefresh = onDisk.refreshToken,
                   onDiskRefresh != refreshToken,
                   let storedExpiresAt = onDisk.expiresAt,
                   !ClaudeTokenRefresher.isExpired(expiresAt: storedExpiresAt, skew: 0) {
                    return Refreshed(
                        accessToken: onDisk.accessToken,
                        refreshToken: onDiskRefresh,
                        expiresAt: storedExpiresAt
                    )
                }
                // 5) 软恢复也没救回来:**后台**启动委托刷新,不阻塞本次调用。
                //    设计上立刻抛 tokenRevoked 让 UI 一秒内收到结果;后台委托刷新
                //    成功时会通过 NotificationCenter 通知 AppState 自动再触发一次
                //    刷新,UI 自然更新到新数据。
                //    这样用户点刷新永远不会等 10 秒,体感"无感后台自愈"。
                log.warning("soft-recovery failed, kicking off background delegated refresh")
                ClaudeDelegatedRefresh.attemptInBackground(source: source)
                throw QuotaError.tokenRevoked
            }
        }
    }

    // MARK: - Network

    nonisolated private static func performNetworkRefresh(
        using refreshToken: String
    ) async throws -> Refreshed {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        req.httpBody = (comps.percentEncodedQuery ?? "").data(using: .utf8)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw QuotaError.tokenRefreshFailed("transport: \(error)")
        }
        guard let http = resp as? HTTPURLResponse else {
            throw QuotaError.tokenRefreshFailed("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            // 400 + invalid_grant = refresh_token 被服务端拒绝。映射到专用错误码,
            // 让上层 Coordinator 走"软恢复"路径,而不是直接报红。
            if http.statusCode == 400, msg.contains("invalid_grant") {
                throw QuotaError.tokenRevoked
            }
            throw QuotaError.tokenRefreshFailed("http \(http.statusCode): \(msg)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.tokenRefreshFailed("invalid json")
        }
        guard let newAccess = root["access_token"] as? String else {
            throw QuotaError.tokenRefreshFailed("no access_token in response")
        }
        let newRefresh = root["refresh_token"] as? String ?? refreshToken
        let expiresIn: TimeInterval = {
            if let n = root["expires_in"] as? Double { return n }
            if let i = root["expires_in"] as? Int { return TimeInterval(i) }
            return 3600
        }()
        let expiresAt = Date(timeIntervalSinceNow: expiresIn)
        return Refreshed(accessToken: newAccess, refreshToken: newRefresh, expiresAt: expiresAt)
    }

    // MARK: - Peek stored credentials (cheap re-read, bypass ClaudeAuth.load)

    nonisolated static func peekStored(source: CredentialSource) -> StoredSnapshot? {
        switch source {
        case .file: return peekFile()
        case .keychain: return peekKeychain()
        }
    }

    nonisolated private static func peekFile() -> StoredSnapshot? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return parseOAuth(oauth)
    }

    nonisolated private static func peekKeychain() -> StoredSnapshot? {
        guard let root = try? readKeychainJSON(),
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return parseOAuth(oauth)
    }

    nonisolated private static func parseOAuth(_ oauth: [String: Any]) -> StoredSnapshot? {
        let access = oauth["accessToken"] as? String ?? oauth["access_token"] as? String
        guard let access, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String
        let expiresAt: Date? = {
            if let n = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            if let s = oauth["expiresAt"] as? String, let n = Double(s) {
                return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
            }
            return nil
        }()
        return StoredSnapshot(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    nonisolated static func fileMtimeWithinPoliteWindow() -> Bool {
        let url = credentialsFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(mtime) < politeMtimeWindow
    }

    nonisolated private static func credentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    // MARK: - Write back

    nonisolated private static func writeBack(
        source: CredentialSource,
        refreshed: Refreshed
    ) throws {
        switch source {
        case .file:
            try writeBackToFile(refreshed: refreshed)
        case .keychain:
            try writeBackToKeychain(refreshed: refreshed)
        }
    }

    nonisolated private static func writeBackToFile(refreshed: Refreshed) throws {
        let url = credentialsFileURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = refreshed.accessToken
        oauth["refreshToken"] = refreshed.refreshToken
        // Claude CLI 用毫秒时间戳
        oauth["expiresAt"] = Int(refreshed.expiresAt.timeIntervalSince1970 * 1000)
        root["claudeAiOauth"] = oauth
        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: url, options: [.atomic])
    }

    nonisolated private static func writeBackToKeychain(refreshed: Refreshed) throws {
        // 读出原 JSON,更新 token 字段后整体回写,保留其他字段(subscriptionType 等)。
        let existing = try readKeychainJSON()
        var root = existing
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = refreshed.accessToken
        oauth["refreshToken"] = refreshed.refreshToken
        oauth["expiresAt"] = Int(refreshed.expiresAt.timeIntervalSince1970 * 1000)
        root["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        guard let str = String(data: data, encoding: .utf8) else {
            throw QuotaError.tokenRefreshFailed("encode keychain payload failed")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-generic-password",
            "-U",
            "-s", keychainService,
            "-a", NSUserName(),
            "-w", str,
        ]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "exit \(proc.terminationStatus)"
            throw QuotaError.tokenRefreshFailed("keychain write failed: \(msg)")
        }
    }

    nonisolated private static func readKeychainJSON() throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, !out.isEmpty,
              let str = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let data = str.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw QuotaError.tokenRefreshFailed("read keychain for merge failed")
        }
        return root
    }
}
