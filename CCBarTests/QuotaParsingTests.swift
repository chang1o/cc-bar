import XCTest
@testable import CCBar

final class QuotaParsingTests: XCTestCase {
    func testCodexNormalResponseKeepsFiveHourPrimaryAndWeeklySecondary() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 18_000,
            secondarySeconds: 604_800
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.remainingPercent, 68)
    }

    func testCodexTemporaryWeeklyOnlyResponseUsesWeeklyAsPrimary() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 604_800,
            secondarySeconds: nil
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .weekly)
        XCTAssertNil(fetched.snapshot.secondaryLimit)
        XCTAssertNil(fetched.snapshot.fiveHour)
        XCTAssertEqual(fetched.snapshot.weekly?.remainingPercent, 68)
    }

    func testCodexUnknownWindowDoesNotPretendToBeFiveHour() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 86_400,
            secondarySeconds: nil
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .unknown)
        XCTAssertNil(fetched.snapshot.fiveHour)
        XCTAssertNil(fetched.snapshot.weekly)
    }

    func testClaudeMergesLegacyWindowsAndDynamicFableLimit() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 2.0, "resets_at": "2026-07-13T02:30:00.424333+00:00"],
            "seven_day": ["utilization": 0.0, "resets_at": NSNull()],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": NSNull(),
            "limits": [
                [
                    "kind": "session",
                    "percent": 2,
                    "resets_at": "2026-07-13T02:30:00.424333+00:00",
                    "is_active": true,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_all",
                    "percent": 0,
                    "resets_at": NSNull(),
                    "is_active": false,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_scoped",
                    "percent": 0,
                    "resets_at": NSNull(),
                    "is_active": false,
                    "scope": [
                        "model": ["display_name": "Fable", "id": NSNull()],
                        "surface": NSNull(),
                    ],
                ],
            ],
        ]

        let snapshot = ClaudeQuotaClient.parse(root: root)

        XCTAssertEqual(snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.modelLimits.count, 1)
        XCTAssertEqual(snapshot.modelLimits.first?.displayName, "Fable")
        XCTAssertEqual(snapshot.modelLimits.first?.kind, .modelWeekly)
        XCTAssertEqual(snapshot.modelLimits.first?.window.remainingPercent, 100)
    }

    func testMissingResetCarriesOnlyStillValidMatchingReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let old = snapshot(
            kind: .weekly,
            usedPercent: 1,
            reset: Date(timeIntervalSince1970: 2_000)
        )
        let fresh = snapshot(kind: .weekly, usedPercent: 2, reset: nil)

        XCTAssertEqual(
            fresh.preservingFutureResetDates(from: old, now: now).primaryWindow?.resetsAt,
            Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertNil(
            fresh.preservingFutureResetDates(
                from: old,
                now: Date(timeIntervalSince1970: 3_000)
            ).primaryWindow?.resetsAt
        )
    }

    func testLegacyCodexCacheReclassifiesSevenDayFiveHourSlot() throws {
        let data = Data("""
        {
          "app": "codex",
          "fiveHour": {"usedPercent": 1, "resetsAt": null, "windowSeconds": 604800},
          "weekly": null,
          "weeklyOpus": null,
          "weeklySonnet": null,
          "geminiWindow": null,
          "geminiWeekly": null,
          "planType": "plus",
          "fetchedAt": 0
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertNil(snapshot.secondaryLimit)
    }

    func testMenuBarBothDoesNotDuplicateWeeklyOnlyPrimary() {
        let weeklyOnly = snapshot(kind: .weekly, usedPercent: 1, reset: nil)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .primary).count, 1)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .weekly).count, 1)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .both).count, 1)
    }

    func testHistoryResetsBaselineWhenPrimaryKindChanges() {
        let start = Date(timeIntervalSince1970: 1_000)
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 1, reset: nil),
            sampledAt: start
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 2, reset: nil),
            sampledAt: start.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)

        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 40, reset: nil),
            sampledAt: start.addingTimeInterval(120)
        )

        XCTAssertTrue(payload.events.isEmpty)
        XCTAssertEqual(payload.lastSamples["codex:primary"]?.limitKind, .fiveHour)
    }

    private func codexRoot(
        primarySeconds: Int,
        secondarySeconds: Int?
    ) -> [String: Any] {
        var rate: [String: Any] = [
            "primary_window": [
                "used_percent": 32,
                "limit_window_seconds": primarySeconds,
                "reset_at": 1_800_000_000,
            ],
        ]
        if let secondarySeconds {
            rate["secondary_window"] = [
                "used_percent": 12,
                "limit_window_seconds": secondarySeconds,
                "reset_at": 1_800_100_000,
            ]
        } else {
            rate["secondary_window"] = NSNull()
        }
        return ["plan_type": "plus", "rate_limit": rate]
    }

    private func snapshot(
        kind: QuotaLimitKind,
        usedPercent: Double,
        reset: Date?
    ) -> QuotaSnapshot {
        let seconds: Int?
        switch kind {
        case .fiveHour: seconds = 18_000
        case .weekly, .modelWeekly: seconds = 604_800
        case .unknown: seconds = nil
        }
        let window = QuotaWindow(
            usedPercent: usedPercent,
            resetsAt: reset,
            windowSeconds: seconds
        )
        return QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(kind: kind, window: window),
            secondaryLimit: nil,
            planType: "plus",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
