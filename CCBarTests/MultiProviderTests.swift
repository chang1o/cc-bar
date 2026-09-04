import CryptoKit
import XCTest
@testable import CCBar

/// Parsers, pace math, keystore decoding and cache codec for the ccpm-driven
/// providers (Kimi, GLM), the key-signed Ollama Cloud API, plus the Claude extra-usage lane.
/// Fixtures mirror real responses captured on 2026-09-04.
final class MultiProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private lazy var iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Helpers

    /// Every lane in display order: primary, secondary, auxiliary, model.
    private func lanes(_ snapshot: QuotaSnapshot) -> [QuotaLimit] {
        [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 }
            + snapshot.auxiliaryLimits
            + snapshot.modelLimits
    }

    private func lane(_ snapshot: QuotaSnapshot, kind: QuotaLimitKind) -> QuotaLimit? {
        lanes(snapshot).first { $0.kind == kind }
    }

    private func lane(_ snapshot: QuotaSnapshot, id: String) -> QuotaLimit? {
        lanes(snapshot).first { $0.id == id }
    }

    private func json(_ text: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        return object as? [String: Any] ?? [:]
    }

    // MARK: - Kimi

    private let kimiJSON = """
    {
      "usage": {"limit": "2048", "used": "214", "remaining": "1834", "resetTime": "2027-01-09T15:23:13.716839300Z"},
      "limits": [{
        "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
        "detail": {"limit": "200", "used": 139, "remaining": "61", "resetTime": "2027-01-06T13:33:02Z"}
      }]
    }
    """

    func testKimiParsesWeeklyRequestsAndFiveHourRateLimit() throws {
        let snapshot = try KimiQuotaClient.parse(data: Data(kimiJSON.utf8), now: now)

        XCTAssertEqual(snapshot.app, .kimi)
        XCTAssertNotNil(snapshot.primaryLimit)
        XCTAssertNotNil(snapshot.secondaryLimit)

        let fiveHour = try XCTUnwrap(lane(snapshot, kind: .fiveHour))
        XCTAssertEqual(fiveHour.window.usedPercent, 69.5, accuracy: 0.01)
        XCTAssertEqual(fiveHour.window.windowSeconds, 18_000)
        XCTAssertEqual(fiveHour.window.detail, "139/200 requests")
        XCTAssertEqual(fiveHour.window.resetsAt, iso.date(from: "2027-01-06T13:33:02Z"))

        let weekly = try XCTUnwrap(lane(snapshot, kind: .weekly))
        XCTAssertEqual(weekly.window.usedPercent, 10.45, accuracy: 0.01)
        XCTAssertEqual(weekly.window.detail, "214/2048 requests")
        XCTAssertNotNil(weekly.window.resetsAt)
    }

    func testKimiToleratesMissingRateLimitBlock() throws {
        let weeklyOnly = """
        {"usage": {"limit": "2048", "used": "0", "remaining": "2048"}}
        """
        let snapshot = try KimiQuotaClient.parse(data: Data(weeklyOnly.utf8), now: now)

        XCTAssertEqual(lanes(snapshot).count, 1)
        let weekly = try XCTUnwrap(lane(snapshot, kind: .weekly))
        XCTAssertEqual(weekly.window.usedPercent, 0, accuracy: 0.001)
        XCTAssertNil(weekly.window.resetsAt)
    }

    func testKimiUsageURLDerivesFromProfileBaseURL() {
        XCTAssertEqual(
            KimiQuotaClient.usageURL(baseURL: URL(string: "https://api.kimi.com/coding/")!).absoluteString,
            "https://api.kimi.com/coding/v1/usages"
        )
    }

    // MARK: - GLM

    private func glmMillis(offset: TimeInterval) -> Int {
        Int((now.timeIntervalSince1970 + offset) * 1000)
    }

    func testGLMDualTokenLimitsBecomeFiveHourPrimaryAndWeeklySecondary() throws {
        let body = """
        {"success": true, "code": 200, "data": {"planName": "Pro", "limits": [
          {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 40, "usage": 1000, "currentValue": 400, "nextResetTime": \(glmMillis(offset: 3600))},
          {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 12, "nextResetTime": \(glmMillis(offset: 3 * 86_400))},
          {"type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 3, "usage": 100, "remaining": 97}
        ]}}
        """
        let snapshot = try GLMQuotaClient.parse(data: Data(body.utf8), now: now)

        XCTAssertEqual(snapshot.app, .glm)
        XCTAssertEqual(snapshot.planType, "Pro")

        let primary = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(primary.kind, .fiveHour)
        XCTAssertEqual(primary.window.usedPercent, 40, accuracy: 0.01)
        XCTAssertNotNil(primary.window.resetsAt, "a reset one hour out is plausible for a 5-hour window")

        let secondary = try XCTUnwrap(snapshot.secondaryLimit)
        XCTAssertEqual(secondary.kind, .weekly)
        XCTAssertEqual(secondary.window.usedPercent, 12, accuracy: 0.01)

        let mcp = try XCTUnwrap(lane(snapshot, id: "mcp"))
        XCTAssertEqual(mcp.kind, .unknown)
        XCTAssertEqual(mcp.displayName, "MCP")
        XCTAssertEqual(mcp.window.usedPercent, 3, accuracy: 0.01)
    }

    func testGLMSingleCreditLimitDropsImplausibleFiveHourReset() throws {
        let body = """
        {"success": true, "code": 200, "data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 55, "nextResetTime": \(glmMillis(offset: 10 * 3600))}
        ]}}
        """
        let snapshot = try GLMQuotaClient.parse(data: Data(body.utf8), now: now)

        let primary = try XCTUnwrap(snapshot.primaryLimit)
        XCTAssertEqual(primary.kind, .fiveHour)
        XCTAssertEqual(primary.window.usedPercent, 55, accuracy: 0.01)
        XCTAssertNil(primary.window.resetsAt, "a 5-hour window cannot reset 10 hours from now")
        XCTAssertNil(snapshot.secondaryLimit)
    }

    func testGLMRejectedResponseSurfacesAsHTTPError() {
        let body = #"{"success": false, "code": 401, "msg": "bad key"}"#
        XCTAssertThrowsError(try GLMQuotaClient.parse(data: Data(body.utf8), now: now)) { error in
            XCTAssertEqual((error as? QuotaError)?.httpStatusCode, 401)
        }
    }

    // MARK: - Ollama Cloud

    /// Real `GET https://ollama.com/api/usage` response captured on 2026-09-05 (signed with
    /// the local key). `usage` is a fraction of the plan allowance.
    private let ollamaUsageJSON = """
    {"activity":{"cost":"0.00000","period":{"type":"last_4_weeks","starting_at":"2026-08-10T00:00:00Z","ending_at":"2026-09-04T16:41:37.866305279Z"},"models":[]},
     "limits":{"monthly":{"usage":0.108,"models":[{"name":"glm-5.3","request_count":994},{"name":"deepseek-v4-flash:0731","request_count":334},{"name":"glm-5.3-flash","request_count":178},{"name":"web search","request_count":23}]}}}
    """

    func testOllamaUsageMonthlyLaneFromFraction() throws {
        let snapshot = try OllamaCloudQuotaClient.parseUsage(data: Data(ollamaUsageJSON.utf8), planType: "max", now: now)

        XCTAssertEqual(snapshot.app, .ollama)
        XCTAssertEqual(snapshot.planType, "max")
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertNil(snapshot.secondaryLimit)
        XCTAssertTrue(snapshot.auxiliaryLimits.isEmpty)

        let monthly = try XCTUnwrap(lane(snapshot, id: "monthly"))
        XCTAssertEqual(snapshot.primaryLimit?.id, "monthly")
        XCTAssertEqual(monthly.kind, .unknown)
        XCTAssertEqual(monthly.displayName, "Monthly")
        XCTAssertEqual(monthly.window.usedPercent, 10.8, accuracy: 0.01)
        XCTAssertEqual(monthly.window.detail, "1529 requests")
        XCTAssertNil(monthly.window.resetsAt)
    }

    func testOllamaUsageMapsAdditionalWindowsByName() throws {
        let json = """
        {"limits":{"weekly":{"usage":0.5,"models":[]},"monthly":{"usage":0.25,"models":[{"name":"x","request_count":3}]},"hourly":{"usage":0.9}}}
        """
        let snapshot = try OllamaCloudQuotaClient.parseUsage(data: Data(json.utf8), planType: nil, now: now)

        XCTAssertEqual(snapshot.primaryLimit?.id, "monthly")
        XCTAssertEqual(snapshot.primaryLimit?.window.detail, "3 requests")
        let weekly = try XCTUnwrap(snapshot.secondaryLimit)
        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(weekly.window.usedPercent, 50, accuracy: 0.01)
        let hourly = try XCTUnwrap(lane(snapshot, kind: .fiveHour))
        XCTAssertEqual(hourly.window.usedPercent, 90, accuracy: 0.01)
        XCTAssertNil(snapshot.planType)
    }

    func testOllamaUsageWithoutLimitsIsADecodeError() {
        XCTAssertThrowsError(try OllamaCloudQuotaClient.parseUsage(data: Data("{\"activity\":{}}".utf8), planType: nil, now: now))
        XCTAssertThrowsError(try OllamaCloudQuotaClient.parseUsage(data: Data("{\"limits\":{}}".utf8), planType: nil, now: now))
    }

    func testOllamaIdentityAcceptsCapitalisedAndLowercaseKeys() throws {
        let remote = try OllamaCloudQuotaClient.parseIdentity(data: Data("""
        {"ID":"7f03","CreatedAt":"2026-06-26T01:46:14Z","Email":"someone@example.com","Name":"someone","Bio":"","AvatarURL":"/x","Plan":"max"}
        """.utf8))
        XCTAssertEqual(remote, OllamaCloudQuotaClient.Identity(name: "someone", email: "someone@example.com", plan: "max"))
        XCTAssertEqual(remote.accountKey, "someone@example.com")

        let local = try OllamaCloudQuotaClient.parseIdentity(data: Data("""
        {"id":"7f03","email":"someone@example.com","name":"someone","avatarurl":"/x","plan":"max"}
        """.utf8))
        XCTAssertEqual(local, remote)

        XCTAssertThrowsError(try OllamaCloudQuotaClient.parseIdentity(data: Data("{\"Bio\":\"\"}".utf8)))
    }

    func testOllamaChallengeMatchesGoClientFormat() {
        XCTAssertEqual(OllamaLocalKey.challenge(method: "GET", path: "/api/usage", ts: "1700000000"), "GET,/api/usage?ts=1700000000")
        XCTAssertEqual(OllamaLocalKey.challenge(method: "POST", path: "/api/me", ts: "1"), "POST,/api/me?ts=1")
    }

    /// Throwaway key generated with `ssh-keygen -t ed25519 -N "" -C ccbar-test`; never used anywhere.
    private let ollamaTestPrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAjM6EIcDu9XEagCxQe+8aTuZfcqVHoc3oGfrqXWQuHcgAAAJBIZiUVSGYl
    FQAAAAtzc2gtZWQyNTUxOQAAACAjM6EIcDu9XEagCxQe+8aTuZfcqVHoc3oGfrqXWQuHcg
    AAAECGfAiYDCf2QzIgEk54bFKP9Gz6U7K5y71XI+rgdVKLbCMzoQhwO71cRqALFB77xpO5
    l9ypUehzegZ+updZC4dyAAAACmNjYmFyLXRlc3QBAgM=
    -----END OPENSSH PRIVATE KEY-----
    """
    private let ollamaTestPublicBlob = "AAAAC3NzaC1lZDI1NTE5AAAAICMzoQhwO71cRqALFB77xpO5l9ypUehzegZ+updZC4dy"

    func testOllamaLocalKeySignsLikeTheGoClient() throws {
        let key = try OllamaLocalKey.parse(pem: ollamaTestPrivateKey)
        XCTAssertEqual(key.publicKeyBase64, ollamaTestPublicBlob)

        let token = try key.authorization(method: "GET", path: "/api/usage", ts: "1700000000")
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], ollamaTestPublicBlob)

        // The SSH public key blob ends with the raw 32-byte ed25519 key.
        let blob = try XCTUnwrap(Data(base64Encoded: ollamaTestPublicBlob))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: blob.suffix(32))
        let signature = try XCTUnwrap(Data(base64Encoded: parts[1]))
        let challenge = Data(OllamaLocalKey.challenge(method: "GET", path: "/api/usage", ts: "1700000000").utf8)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: challenge))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("GET,/api/usage?ts=1700000001".utf8)))
        XCTAssertTrue(key.verify(signatureBase64: parts[1], method: "GET", path: "/api/usage", ts: "1700000000"))
    }

    func testOllamaLocalKeyRejectsNonOpenSSHInput() {
        XCTAssertThrowsError(try OllamaLocalKey.parse(pem: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----")) { error in
            guard case OllamaLocalKey.LoadError.notOpenSSH = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try OllamaLocalKey.parse(pem: "not a key"))
    }

    // MARK: - Claude extra usage

    func testClaudeExtraUsageBecomesAuxiliaryLane() throws {
        let root = json("""
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2027-01-06T13:33:02Z"},
          "seven_day": {"utilization": 40, "resets_at": "2027-01-09T15:23:13.716839300Z"},
          "seven_day_opus": {"utilization": 20, "resets_at": "2027-01-09T15:23:13Z"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 200000, "used_credits": 1234, "utilization": 0.617, "currency": "USD"}
        }
        """)
        let snapshot = ClaudeQuotaClient.parse(root: root)

        XCTAssertEqual(snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.modelLimits.first?.displayName, "Opus")

        let extra = try XCTUnwrap(snapshot.auxiliaryLimits.first { $0.id == "extra-usage" })
        XCTAssertEqual(extra.kind, .unknown)
        XCTAssertEqual(extra.displayName, "Extra usage")
        XCTAssertEqual(extra.window.usedPercent, 0.617, accuracy: 0.001)
        XCTAssertEqual(extra.window.detail, "$12.34 / $2000.00", "credits are cents")
        XCTAssertNil(extra.window.windowSeconds)
        XCTAssertNil(extra.window.resetsAt)
    }

    func testClaudeDisabledExtraUsageYieldsNoLane() {
        let root = json("""
        {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 9},
         "extra_usage": {"is_enabled": false, "monthly_limit": 200000, "used_credits": 0}}
        """)
        let snapshot = ClaudeQuotaClient.parse(root: root)
        XCTAssertNil(snapshot.auxiliaryLimits.first { $0.id == "extra-usage" })
    }

    func testClaudeExtraUsagePercentFallsBackToUsedOverLimit() throws {
        let root = json("""
        {"five_hour": {"utilization": 5},
         "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 2500}}
        """)
        let snapshot = ClaudeQuotaClient.parse(root: root)
        let extra = try XCTUnwrap(snapshot.auxiliaryLimits.first { $0.id == "extra-usage" })
        XCTAssertEqual(extra.window.usedPercent, 25, accuracy: 0.01)
    }

    // MARK: - Codex Pro 20x (weekly-only)

    func testCodexWeeklyOnlyPlanHasWeeklyPrimaryAndNoSecondary() {
        let root: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 26,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_800_100_000,
                ],
                "secondary_window": NSNull(),
            ],
        ]
        let fetched = CodexQuotaClient.parse(root: root)

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.primaryLimit?.window.usedPercent, 26)
        XCTAssertNil(fetched.snapshot.secondaryLimit)
        XCTAssertEqual(fetched.snapshot.planType, "pro")
    }

    // MARK: - Pace

    private func fiveHour(used: Double, resetIn seconds: TimeInterval) -> QuotaLimit {
        .standard(
            kind: .fiveHour,
            window: QuotaWindow(usedPercent: used, resetsAt: now.addingTimeInterval(seconds), windowSeconds: 18_000)
        )
    }

    func testPaceOnTrackHasZeroDeltaAndNoRunOut() throws {
        let pace = try XCTUnwrap(QuotaPace.compute(limit: fiveHour(used: 50, resetIn: 9_000), now: now))
        XCTAssertEqual(pace.deltaPercent, 0, accuracy: 0.001)
        XCTAssertNil(pace.runsOutAt)
        XCTAssertFalse(pace.isAhead)
    }

    func testPaceAheadProjectsRunOut() throws {
        let pace = try XCTUnwrap(QuotaPace.compute(limit: fiveHour(used: 80, resetIn: 9_000), now: now))
        XCTAssertEqual(pace.deltaPercent, 30, accuracy: 0.001)
        XCTAssertTrue(pace.isAhead)
        // 80% in 9000s -> 100% at 11250s elapsed -> 2250s from now.
        let runsOut = try XCTUnwrap(pace.runsOutAt)
        XCTAssertEqual(runsOut.timeIntervalSince(now), 2_250, accuracy: 1)
    }

    func testPaceBehindIsNegative() throws {
        let pace = try XCTUnwrap(QuotaPace.compute(limit: fiveHour(used: 20, resetIn: 9_000), now: now))
        XCTAssertEqual(pace.deltaPercent, -30, accuracy: 0.001)
        XCTAssertNil(pace.runsOutAt)
    }

    func testPaceIsNilUnderThreePercentElapsed() {
        XCTAssertNil(QuotaPace.compute(limit: fiveHour(used: 5, resetIn: 17_900), now: now))
    }

    func testPaceIsNilWithoutReset() {
        let limit = QuotaLimit.standard(
            kind: .fiveHour,
            window: QuotaWindow(usedPercent: 50, resetsAt: nil, windowSeconds: 18_000)
        )
        XCTAssertNil(QuotaPace.compute(limit: limit, now: now))
    }

    func testPaceFallsBackToKindDefaultWindowSeconds() throws {
        let weekly = QuotaLimit.standard(
            kind: .weekly,
            window: QuotaWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(3.5 * 86_400), windowSeconds: nil)
        )
        let pace = try XCTUnwrap(QuotaPace.compute(limit: weekly, now: now))
        XCTAssertEqual(pace.deltaPercent, 0, accuracy: 0.001)
    }

    // MARK: - ccpm keystore

    func testKeystoreDecodesGoKeyringEncodings() {
        XCTAssertEqual(CCPMKeystore.decode("go-keyring-base64:c2stdGVzdA=="), "sk-test")
        XCTAssertEqual(CCPMKeystore.decode("go-keyring-encoded:736b2d74657374"), "sk-test")
        XCTAssertEqual(CCPMKeystore.decode("plain-value"), "plain-value")
    }

    // MARK: - Cache codec

    func testQuotaCachePayloadRoundTripsCCPMAccounts() throws {
        let snapshot = QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: 43, resetsAt: now.addingTimeInterval(3_600), windowSeconds: 18_000)
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 26, resetsAt: now.addingTimeInterval(86_400), windowSeconds: 604_800)
            ),
            auxiliaryLimits: [
                QuotaLimit(
                    id: "extra-usage",
                    kind: .unknown,
                    displayName: "Extra usage",
                    window: QuotaWindow(usedPercent: 0.617, resetsAt: nil, windowSeconds: nil, detail: "$12.34 / $2000.00"),
                    isActive: nil
                ),
            ],
            planType: "max",
            fetchedAt: now
        )
        var payload = QuotaCachePayload()
        payload.ccpmAccounts = [
            "claude:ccpm:zxliu": QuotaCacheRecord(snapshot: snapshot, source: .api, updatedAt: now),
        ]

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(QuotaCachePayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        let record = try XCTUnwrap(decoded.ccpmAccounts?["claude:ccpm:zxliu"])
        XCTAssertEqual(record.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(record.snapshot.auxiliaryLimits.first?.window.detail, "$12.34 / $2000.00")

        // The ccpm status line reads this file with a Go decoder: keep the raw shape stable.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(root["ccpmAccounts"] as? [String: Any])
        let raw = try XCTUnwrap(accounts["claude:ccpm:zxliu"] as? [String: Any])
        let rawSnapshot = try XCTUnwrap(raw["snapshot"] as? [String: Any])
        let rawPrimary = try XCTUnwrap(rawSnapshot["primaryLimit"] as? [String: Any])
        XCTAssertEqual(rawPrimary["kind"] as? String, "fiveHour")
        XCTAssertEqual((rawPrimary["window"] as? [String: Any])?["usedPercent"] as? Double, 43)
        XCTAssertNotNil(raw["updatedAt"] as? Double, "Apple reference seconds, consumed by ccpm")
    }

    func testQuotaCachePayloadWithoutCCPMAccountsStillDecodes() throws {
        let data = Data(#"{"version": 4, "providers": {}}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaCachePayload.self, from: data)
        XCTAssertNil(decoded.ccpmAccounts)
    }
}
