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

    func testCycleStoreRecordsFiveHourAndWeeklyButExcludesModelWeekly() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let fiveHourEnd = sampledAt.addingTimeInterval(18_000)
        let weeklyEnd = sampledAt.addingTimeInterval(604_800)
        let snapshot = QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: 12, resetsAt: fiveHourEnd, windowSeconds: 18_000)
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 34, resetsAt: weeklyEnd, windowSeconds: 604_800)
            ),
            modelLimits: [
                .model(
                    id: "opus",
                    displayName: "Opus",
                    window: QuotaWindow(usedPercent: 50, resetsAt: weeklyEnd, windowSeconds: 604_800),
                    isActive: true
                )
            ],
            planType: nil,
            fetchedAt: sampledAt
        )

        let result = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot,
            source: .api,
            sampledAt: sampledAt
        )

        XCTAssertEqual(Set(result.records.map(\.limitKind)), Set([.fiveHour, .weekly]))
        XCTAssertEqual(result.records.count, 2)
    }

    func testCycleStoreRecordsInactiveWeeklyWindow() {
        // is_active 只表示「当前哪个限制在起约束作用」；非当前约束的 weekly
        // 窗口同样返回有效 percent，周期记录必须继续采样，否则页面停在旧值。
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let weeklyEnd = sampledAt.addingTimeInterval(604_800)
        let snapshot = QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: 12, resetsAt: sampledAt.addingTimeInterval(18_000), windowSeconds: 18_000),
                isActive: true
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 34, resetsAt: weeklyEnd, windowSeconds: 604_800),
                isActive: false
            ),
            modelLimits: [],
            planType: nil,
            fetchedAt: sampledAt
        )

        let result = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot,
            source: .api,
            sampledAt: sampledAt
        )

        let weeklyRecord = result.records.first { $0.limitKind == .weekly }
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(weeklyRecord?.latestUsedPercent, 34)
        XCTAssertEqual(weeklyRecord?.allowanceSegments.first?.maximumUsedPercent, 34)
    }

    func testCycleStoreDeduplicatesSnapshotsAndRollsAtNewReset() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 25, reset: firstReset),
            source: .api,
            sampledAt: sampledAt.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.records.count, 1)
        XCTAssertEqual(payload.records.first?.latestUsedPercent, 25)
        XCTAssertEqual(payload.records.first?.latestAllowanceSegment?.maximumUsedPercent, 25)

        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(
                kind: .fiveHour,
                usedPercent: 1,
                reset: firstReset.addingTimeInterval(18_000)
            ),
            source: .api,
            sampledAt: firstReset.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.records.count, 2)
    }

    func testCycleStoreCreatesNewAllowanceWhenUsageResetsWithoutChangingResetTime() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let resetAt = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 80, reset: resetAt),
            source: .api,
            sampledAt: sampledAt
        )
        let benefitResetAt = sampledAt.addingTimeInterval(60)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 0, reset: resetAt),
            source: .api,
            sampledAt: benefitResetAt
        )

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1)
        XCTAssertEqual(cycle.latestUsedPercent, 0)
        XCTAssertEqual(cycle.extraResetCount, 1)
        XCTAssertEqual(cycle.allowanceSegments.count, 2)
        XCTAssertEqual(cycle.allowanceSegments[0].endAt, benefitResetAt)
        XCTAssertEqual(cycle.allowanceSegments[1].startReason, .extraReset)
        XCTAssertEqual(cycle.allowanceSegments[1].baselineUsedPercent, 0)
    }

    func testCycleStoreDoesNotTreatSmallPercentageCorrectionAsExtraReset() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let resetAt = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 25, reset: resetAt),
            source: .api,
            sampledAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 24, reset: resetAt),
            source: .api,
            sampledAt: sampledAt.addingTimeInterval(60)
        )

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(cycle.extraResetCount, 0)
        XCTAssertEqual(cycle.latestUsedPercent, 24)
        XCTAssertEqual(cycle.latestAllowanceSegment?.maximumUsedPercent, 25)
    }

    func testCycleStoreClosesOverlappingCycleWhenOfficialResetTimeChanges() throws {
        let firstStart = Date(timeIntervalSince1970: 100_000)
        let firstReset = firstStart.addingTimeInterval(604_800)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: firstStart),
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .weekly, usedPercent: 40, reset: firstReset),
            source: .api,
            sampledAt: firstStart
        )
        let newStart = firstStart.addingTimeInterval(3_600)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 0,
                reset: newStart.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: newStart
        )

        XCTAssertEqual(payload.records.count, 2)
        let oldCycle = try XCTUnwrap(payload.records.first { $0.scheduledEndAt == firstReset })
        XCTAssertEqual(oldCycle.endAt, newStart)
        XCTAssertEqual(oldCycle.allowanceSegments.last?.endAt, newStart)
    }

    func testCycleStoreMergesSameCycleWhenResetAtJitters() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(604_800)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        // Codex 服务端 reset_at 秒级抖动：每次返回相差 1~3 秒。
        let jitters: [(TimeInterval, Double)] = [(3, 10), (1, 25), (2, 40)]
        for (index, jitter) in jitters.enumerated() {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "codex:primary:test",
                app: .codex,
                snapshot: snapshot(
                    kind: .weekly,
                    usedPercent: jitter.1,
                    reset: firstReset.addingTimeInterval(jitter.0)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index) * 60)
            )
        }

        XCTAssertEqual(payload.records.count, 1, "reset_at 抖动不应产生重复周期记录")
        XCTAssertEqual(payload.records.first?.latestUsedPercent, 40)
    }

    func testCycleStoreKeepsActiveCycleWhenResetAtDriftsWithoutUsageReset() throws {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let firstReset = sampledAt.addingTimeInterval(604_800)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        let samples: [(minutes: TimeInterval, usedPercent: Double)] = [
            (0, 0),
            (17, 0),
            (19, 0),
            (21, 20),
        ]

        for sample in samples {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "codex:primary:test",
                app: .codex,
                snapshot: snapshot(
                    kind: .weekly,
                    usedPercent: sample.usedPercent,
                    reset: firstReset.addingTimeInterval(sample.minutes * 60)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(sample.minutes * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "额度未回落时 reset_at 分钟级漂移仍属于同一周期")
        XCTAssertEqual(cycle.startAt, sampledAt)
        XCTAssertEqual(cycle.endAt, firstReset.addingTimeInterval(21 * 60))
        XCTAssertEqual(cycle.latestUsedPercent, 20)
        XCTAssertEqual(cycle.allowanceSegments.count, 1)
    }

    func testCycleStoreKeepsScheduledEndAtUnderSubsecondJitter() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        // Claude 服务端 resets_at 亚秒级抖动：容差内应保留既有边界，
        // 否则 cycleUsagePartition 会把漂移误判为周期滚动并触发全量重建。
        let jitters: [(TimeInterval, Double)] = [(0.1, 15), (0.9, 20)]
        for (index, jitter) in jitters.enumerated() {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "claude:primary",
                app: .claude,
                snapshot: snapshot(
                    kind: .fiveHour,
                    usedPercent: jitter.1,
                    reset: firstReset.addingTimeInterval(jitter.0)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index + 1) * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "亚秒抖动不应产生重复周期记录")
        XCTAssertEqual(cycle.scheduledEndAt, firstReset, "亚秒抖动不应改写 scheduledEndAt")
        XCTAssertEqual(cycle.endAt, firstReset, "亚秒抖动不应滚动 endAt")
        XCTAssertEqual(cycle.latestUsedPercent, 20)
    }

    func testCycleStoreRollsScheduledEndAtWhenDriftReachesTolerance() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        // 5s 为容差边界（≥5s 即写入新边界），随后再从 5s 处漂移 6s 应继续更新。
        for (index, drift) in [5, 11].enumerated() {
            let newReset = firstReset.addingTimeInterval(TimeInterval(drift))
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "claude:primary",
                app: .claude,
                snapshot: snapshot(
                    kind: .fiveHour,
                    usedPercent: 10 + Double(index) * 5,
                    reset: newReset
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index + 2) * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "真实滚动仍应复用同一条周期记录")
        XCTAssertEqual(cycle.scheduledEndAt, firstReset.addingTimeInterval(11))
        XCTAssertEqual(cycle.endAt, firstReset.addingTimeInterval(11))
        XCTAssertEqual(cycle.latestUsedPercent, 15)
    }

    func testCleaningUpLegacyPayloadDropsShardsAndMergesOverlaps() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        var payload = QuotaCyclePayload(version: 3, trackingStartedAt: start)
        payload.records = [
            cycleRecord(id: "dup-b", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(3), end: start.addingTimeInterval(3 + week)),
            cycleRecord(id: "dup-a", accountKey: "codex:primary:a", app: .codex,
                        start: start, end: start.addingTimeInterval(week)),
            cycleRecord(id: "shard-1", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(1), end: start.addingTimeInterval(2)),
            cycleRecord(id: "shard-2", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(week + 1), end: start.addingTimeInterval(week + 2)),
        ]

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(payload)

        XCTAssertEqual(cleaned.records.count, 1, "残片应被删除、重叠完整周期应合并为一条")
        let kept = try XCTUnwrap(cleaned.records.first)
        XCTAssertEqual(kept.endAt, start.addingTimeInterval(3 + week), "应保留 endAt 最晚的周期")
        XCTAssertEqual(kept.firstSampleAt, start)
        XCTAssertEqual(kept.lastSampleAt, start.addingTimeInterval(3 + week))
        XCTAssertEqual(kept.reportedUsedPercent, 25, "重复 initial 段不能把额度百分比累加")
    }

    func testCleaningUpPayloadKeepsAdjacentCyclesWithSubsecondBoundaryOverlap() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        // 相邻的两个真实周期，边界分别由各自采样时刻的 resets_at 推出，两侧抖动叠加
        // 会让后一周期的起点比前一周期的终点略早。这种亚秒毛刺不是重复记录：若按
        // 重叠去重，merging 只保留 base 的 startAt / endAt，较早那整段周期历史会被
        // 永久吞掉且无法从日志重建。
        var payload = QuotaCyclePayload(version: 3, trackingStartedAt: start)
        payload.records = [
            cycleRecord(id: "earlier", accountKey: "claude:primary", app: .claude,
                        start: start, end: start.addingTimeInterval(week + 0.67)),
            cycleRecord(id: "later", accountKey: "claude:primary", app: .claude,
                        start: start.addingTimeInterval(week + 0.51),
                        end: start.addingTimeInterval(2 * week)),
        ]

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(payload)

        XCTAssertEqual(cleaned.records.count, 2, "亚秒级边界重叠只是抖动毛刺，两个周期都应保留")
        let earlier = try XCTUnwrap(cleaned.records.first { $0.id == "earlier" })
        XCTAssertEqual(earlier.startAt, start, "较早周期的时间段不应被吞掉")
        XCTAssertEqual(earlier.endAt, start.addingTimeInterval(week + 0.67))
    }

    func testCleaningUpPayloadCoalescesResetDriftButKeepsRealUsageReset() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let trueReset = start.addingTimeInterval(2 * 24 * 60 * 60)
        let minute: TimeInterval = 60

        var beforeReset = cycleRecord(
            id: "before-reset",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: trueReset,
            usedPercent: 100
        )
        beforeReset.scheduledEndAt = start.addingTimeInterval(604_800)

        var fragmentA = cycleRecord(
            id: "fragment-a",
            accountKey: "codex:primary:a",
            app: .codex,
            start: trueReset,
            end: trueReset.addingTimeInterval(17 * minute),
            usedPercent: 0
        )
        fragmentA.scheduledEndAt = trueReset.addingTimeInterval(604_800)

        var fragmentB = cycleRecord(
            id: "fragment-b",
            accountKey: "codex:primary:a",
            app: .codex,
            start: fragmentA.endAt,
            end: fragmentA.endAt.addingTimeInterval(2 * minute),
            usedPercent: 0
        )
        fragmentB.scheduledEndAt = fragmentB.startAt.addingTimeInterval(604_800)

        let current = cycleRecord(
            id: "current",
            accountKey: "codex:primary:a",
            app: .codex,
            start: fragmentB.endAt.addingTimeInterval(1),
            end: fragmentB.endAt.addingTimeInterval(604_801),
            usedPercent: 20
        )

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(QuotaCyclePayload(
            version: 4,
            trackingStartedAt: start,
            records: [current, fragmentB, fragmentA, beforeReset]
        ))

        XCTAssertEqual(cleaned.records.count, 2)
        XCTAssertNotNil(cleaned.records.first { $0.id == "before-reset" }, "100% → 0% 是真实重置")
        let merged = try XCTUnwrap(cleaned.records.first { $0.id == "current" })
        XCTAssertEqual(merged.startAt, trueReset, "相邻片段相差 1 秒仍应合并")
        XCTAssertEqual(merged.latestUsedPercent, 20)
        XCTAssertEqual(merged.reportedUsedPercent, 20)
        XCTAssertEqual(merged.allowanceSegments.count, 1)
    }

    func testCycleStoreCreatesAccountSegmentsWithoutBackdatingSwitchedAccount() {
        let firstSample = Date(timeIntervalSince1970: 100_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: firstSample),
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 20,
                reset: firstSample.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: firstSample
        )
        let switchedAt = firstSample.addingTimeInterval(3_600)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:b",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 5,
                reset: firstSample.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: switchedAt
        )

        XCTAssertEqual(payload.accountSegments.count, 2)
        XCTAssertEqual(payload.accountSegments[0].startAt, firstSample)
        XCTAssertEqual(payload.accountSegments[0].endAt, switchedAt)
        XCTAssertEqual(payload.accountSegments[1].startAt, switchedAt)
        XCTAssertNil(payload.accountSegments[1].endAt)
    }

    func testCycleStoreRequiresResetAndMarksMissingWindowLengthAsInferred() {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let missingReset = QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 10, resetsAt: nil, windowSeconds: 604_800)
            ),
            secondaryLimit: nil,
            planType: nil,
            fetchedAt: sampledAt
        )
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: missingReset,
            source: .api,
            sampledAt: sampledAt
        )
        XCTAssertTrue(payload.records.isEmpty)

        let missingLength = QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(
                    usedPercent: 10,
                    resetsAt: sampledAt.addingTimeInterval(604_800),
                    windowSeconds: nil
                )
            ),
            secondaryLimit: nil,
            planType: nil,
            fetchedAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: missingLength,
            source: .api,
            sampledAt: sampledAt
        )
        XCTAssertEqual(payload.records.first?.boundaryQuality, .inferred)
    }

    func testQuotaCycleV2RecordMigratesIntoInitialAllowanceSegment() throws {
        let data = Data(#"""
        {
          "id": "legacy",
          "accountKey": "codex:primary:test",
          "app": "codex",
          "limitID": "weekly",
          "limitKind": "weekly",
          "startAt": 0,
          "endAt": 604800,
          "firstSampleAt": 0,
          "lastSampleAt": 60,
          "maximumUsedPercent": 37,
          "source": "api",
          "boundaryQuality": "observed"
        }
        """#.utf8)

        let cycle = try JSONDecoder().decode(QuotaCycleRecord.self, from: data)
        XCTAssertEqual(cycle.scheduledEndAt, cycle.endAt)
        XCTAssertEqual(cycle.latestUsedPercent, 37)
        XCTAssertEqual(cycle.allowanceSegments.count, 1)
        XCTAssertEqual(cycle.latestAllowanceSegment?.maximumUsedPercent, 37)
    }

    @MainActor
    func testCycleUsageUsesHalfOpenBoundariesAndDoesNotCrossAccounts() {
        let start = Date(timeIntervalSince1970: 10_000)
        let first = cycleRecord(
            id: "first",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(100)
        )
        let second = cycleRecord(
            id: "second",
            accountKey: "codex:primary:a",
            app: .codex,
            start: first.endAt,
            end: first.endAt.addingTimeInterval(100)
        )
        let otherAccount = cycleRecord(
            id: "other",
            accountKey: "codex:primary:b",
            app: .codex,
            start: start,
            end: second.endAt
        )
        let entry = UsageEntry(
            app: .codex,
            conversationKey: "codex:test",
            model: "gpt-5.6",
            speed: .standard,
            day: UsageDay.startOfDay(for: first.endAt),
            timestamp: first.endAt,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 1,
            costBreakdown: nil
        )
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry],
            cycles: [first, second, otherAccount],
            accountSegments: [QuotaCycleAccountSegment(
                id: "a",
                accountKey: "codex:primary:a",
                app: .codex,
                startAt: start,
                endAt: nil
            )]
        )

        XCTAssertEqual(aggregator.snapshot().count, 1)
        XCTAssertEqual(aggregator.snapshot().first?.cycleID, "second")
    }

    @MainActor
    func testCycleUsageRebuildKeepsEntriesInTheirAccountSegments() {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 200_000))
        let switchedAt = start.addingTimeInterval(3_600)
        let end = start.addingTimeInterval(7_200)
        let oldCycle = cycleRecord(
            id: "old-account",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: end
        )
        let newCycle = cycleRecord(
            id: "new-account",
            accountKey: "codex:primary:b",
            app: .codex,
            start: start,
            end: end
        )
        func entry(at timestamp: Date) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: start,
                timestamp: timestamp,
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry(at: start.addingTimeInterval(60)), entry(at: switchedAt.addingTimeInterval(60))],
            cycles: [oldCycle, newCycle],
            accountSegments: [
                QuotaCycleAccountSegment(
                    id: "a",
                    accountKey: oldCycle.accountKey,
                    app: .codex,
                    startAt: start,
                    endAt: switchedAt
                ),
                QuotaCycleAccountSegment(
                    id: "b",
                    accountKey: newCycle.accountKey,
                    app: .codex,
                    startAt: switchedAt,
                    endAt: nil
                ),
            ]
        )

        XCTAssertEqual(Set(aggregator.snapshot().map(\.cycleID)), Set(["old-account", "new-account"]))
        XCTAssertEqual(aggregator.snapshot().reduce(0) { $0 + $1.inputTokens }, 20)
    }

    func testCycleForecastStartsWithAnyObservedUsage() {
        let cycle = cycleRecord(
            id: "forecast",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 20
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 40
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 200)
        XCTAssertEqual(summary.forecastConfidence, .rough)

        var lowUsage = cycle
        lowUsage.latestUsedPercent = 9.9
        lowUsage.allowanceSegments[0].latestUsedPercent = 9.9
        lowUsage.allowanceSegments[0].maximumUsedPercent = 9.9
        let lowSummary = CycleUsageSummary(
            cycle: lowUsage,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertEqual(lowSummary.projectedFullCycleTokens, 10_101)
        if let projectedCost = lowSummary.projectedFullCycleCostUSD {
            XCTAssertEqual(
                NSDecimalNumber(decimal: projectedCost).doubleValue,
                404.04,
                accuracy: 0.01
            )
        } else {
            XCTFail("Low-observation cost should still be forecast")
        }
        XCTAssertEqual(lowSummary.forecastConfidence, .early)
    }

    func testCycleForecastUsesObservedDeltaAfterNonzeroBaseline() {
        var cycle = cycleRecord(
            id: "baseline",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 40
        )
        cycle.allowanceSegments[0].baselineUsedPercent = 20
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )

        XCTAssertEqual(summary.forecastObservedPercent, 20)
        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 100)

        let incompleteSummary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .incomplete
        )
        XCTAssertEqual(incompleteSummary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(incompleteSummary.projectedFullCycleCostUSD, 100)
        XCTAssertEqual(incompleteSummary.forecastConfidence, .rough)
    }

    func testCycleForecastRequiresObservedUsageAndAValueBasis() {
        var cycle = cycleRecord(
            id: "forecast-basis",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 0
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20

        let noObservedUsage = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertNil(noObservedUsage.projectedFullCycleTokens)
        XCTAssertNil(noObservedUsage.projectedFullCycleCostUSD)
        XCTAssertNil(noObservedUsage.forecastConfidence)

        cycle.latestUsedPercent = 20
        cycle.allowanceSegments[0].latestUsedPercent = 20
        cycle.allowanceSegments[0].maximumUsedPercent = 20

        var tokensOnly = totals
        tokensOnly.costUSD = 0
        let noCostBasis = CycleUsageSummary(
            cycle: cycle,
            totals: tokensOnly,
            currentAllowanceTotals: tokensOnly,
            quality: .exact
        )
        XCTAssertEqual(noCostBasis.projectedFullCycleTokens, 5_000)
        XCTAssertNil(noCostBasis.projectedFullCycleCostUSD)

        let noTokenBasis = CycleUsageSummary(
            cycle: cycle,
            totals: .zero,
            currentAllowanceTotals: .zero,
            quality: .exact
        )
        XCTAssertNil(noTokenBasis.projectedFullCycleTokens)
        XCTAssertNil(noTokenBasis.projectedFullCycleCostUSD)
        XCTAssertNil(noTokenBasis.forecastConfidence)
    }

    func testCycleForecastFallsBackToLatestUsedPercentWhenBaselineIsFull() {
        // 历史遗留坏段（baseline=100 的重复记录合并残留）observed=0 时，
        // 用满预估应回退到最新已用比例，而不是显示 —。
        var cycle = cycleRecord(
            id: "full-baseline",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 100
        )
        cycle.allowanceSegments[0].baselineUsedPercent = 100
        cycle.allowanceSegments[0].maximumUsedPercent = 100
        cycle.allowanceSegments[0].latestUsedPercent = 100

        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20

        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )

        XCTAssertEqual(summary.forecastObservedPercent, 100)
        XCTAssertEqual(summary.projectedFullCycleTokens, 1_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 20)
        XCTAssertEqual(summary.forecastConfidence, .reliable)
    }

    func testCycleForecastUsesKnownCostWhenSomeUsageIsUnpriced() {
        let cycle = cycleRecord(
            id: "partially-unpriced",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 20
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20
        totals.hasUnpricedUsage = true
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .incomplete
        )

        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 100)
        XCTAssertEqual(summary.forecastConfidence, .rough)
    }

    func testCycleForecastKeepsActualUsageBeforeExtraReset() {
        let start = Date(timeIntervalSince1970: 1_000)
        let resetAt = Date(timeIntervalSince1970: 1_500)
        var cycle = cycleRecord(
            id: "benefit-reset",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 80
        )
        cycle.allowanceSegments[0].endAt = resetAt
        cycle.allowanceSegments.append(QuotaCycleAllowanceSegment(
            id: "benefit-reset-current",
            startAt: resetAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: 20,
            maximumUsedPercent: 20,
            firstSampleAt: resetAt,
            lastSampleAt: resetAt.addingTimeInterval(60),
            startReason: .extraReset
        ))
        cycle.latestUsedPercent = 20
        var total = UsageTotals.zero
        total.inputTokens = 5_000
        total.costUSD = 50
        var current = UsageTotals.zero
        current.inputTokens = 1_000
        current.costUSD = 10
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: total,
            currentAllowanceTotals: current,
            quality: .estimated
        )

        XCTAssertEqual(summary.projectedFullCycleTokens, 9_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 90)
    }

    @MainActor
    func testCycleUsageRebuildRangeKeepsHistoryBucketsAndRefillsAffectedOnes() {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 300_000))
        let oldCycle = cycleRecord(
            id: "old-cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start.addingTimeInterval(-30 * 24 * 3_600),
            end: start.addingTimeInterval(-25 * 24 * 3_600)
        )
        let affectedCycle = cycleRecord(
            id: "affected-cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(7_200)
        )
        func entry(at timestamp: Date, input: Int) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let segment = QuotaCycleAccountSegment(
            id: "a",
            accountKey: "codex:primary:a",
            app: .codex,
            startAt: start.addingTimeInterval(-30 * 24 * 3_600),
            endAt: nil
        )
        let aggregator = CycleUsageAggregator()
        // 先灌入历史桶（100 tokens）+ 受影响窗口桶（10 tokens）
        aggregator.ingest(
            entries: [
                entry(at: oldCycle.startAt.addingTimeInterval(60), input: 100),
                entry(at: affectedCycle.startAt.addingTimeInterval(60), input: 10),
            ],
            cycles: [oldCycle, affectedCycle],
            accountSegments: [segment]
        )
        XCTAssertEqual(aggregator.snapshot().count, 2)

        // 受限重建：只重算 affected-cycle，用新条目（50 tokens）重灌
        aggregator.rebuildRange(
            exactEntries: [
                entry(at: affectedCycle.startAt.addingTimeInterval(120), input: 50),
            ],
            cycles: [oldCycle, affectedCycle],
            accountSegments: [segment],
            affectedCycleIDs: ["affected-cycle"]
        )

        let byID = Dictionary(grouping: aggregator.snapshot(), by: \.cycleID)
        XCTAssertEqual(byID["old-cycle"]?.first?.inputTokens, 100, "窗口外的历史桶必须原样保留")
        XCTAssertEqual(byID["affected-cycle"]?.first?.inputTokens, 50, "受影响周期内的桶应被新扫描结果重灌")
        XCTAssertEqual(aggregator.snapshot().count, 2)
    }

    @MainActor
    func testCycleUsageRebuildRangeWithEmptyAffectedSetAppendsOnly() {
        let start = Date(timeIntervalSince1970: 400_000)
        let cycle = cycleRecord(
            id: "cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(3_600)
        )
        func entry(at timestamp: Date, input: Int) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let segment = QuotaCycleAccountSegment(
            id: "a",
            accountKey: "codex:primary:a",
            app: .codex,
            startAt: start,
            endAt: nil
        )
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry(at: start.addingTimeInterval(60), input: 100)],
            cycles: [cycle],
            accountSegments: [segment]
        )
        // 空受影响集合 = 不清任何桶，仅追加
        aggregator.rebuildRange(
            exactEntries: [entry(at: start.addingTimeInterval(120), input: 50)],
            cycles: [cycle],
            accountSegments: [segment],
            affectedCycleIDs: []
        )
        let snapshot = aggregator.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.inputTokens, 150)
    }

    @MainActor
    func testCycleUsageAggregatorSeparatesUsageAcrossAllowanceReset() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let benefitResetAt = Date(timeIntervalSince1970: 1_500)
        var cycle = cycleRecord(
            id: "allowance-buckets",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 80
        )
        cycle.allowanceSegments[0].endAt = benefitResetAt
        cycle.allowanceSegments.append(QuotaCycleAllowanceSegment(
            id: "allowance-buckets-current",
            startAt: benefitResetAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: 20,
            maximumUsedPercent: 20,
            firstSampleAt: benefitResetAt,
            lastSampleAt: benefitResetAt.addingTimeInterval(60),
            startReason: .extraReset
        ))
        cycle.latestUsedPercent = 20
        func entry(at timestamp: Date, tokens: Int) -> UsageEntry {
            UsageEntry(
                app: .claude,
                conversationKey: "claude:test",
                model: "claude-sonnet-5",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: tokens,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: Decimal(tokens) / 100,
                costBreakdown: nil
            )
        }
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [
                entry(at: Date(timeIntervalSince1970: 1_200), tokens: 400),
                entry(at: Date(timeIntervalSince1970: 1_600), tokens: 100),
            ],
            cycles: [cycle],
            accountSegments: [QuotaCycleAccountSegment(
                id: "claude",
                accountKey: cycle.accountKey,
                app: .claude,
                startAt: start,
                endAt: nil
            )]
        )

        let summary = try XCTUnwrap(aggregator.summaries(
            cycles: [cycle],
            kind: .weekly,
            app: .claude,
            now: cycle.endAt.addingTimeInterval(1)
        ).first)
        XCTAssertEqual(summary.totals.totalTokens, 500)
        XCTAssertEqual(summary.currentAllowanceTotals.totalTokens, 100)
        XCTAssertEqual(summary.projectedFullCycleTokens, 900)
    }

    func testCycleSummaryDistinguishesEmptyInferredHistory() {
        let cycle = cycleRecord(
            id: "empty-history",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let empty = CycleUsageSummary(cycle: cycle, totals: .zero, quality: .estimated)
        XCTAssertFalse(empty.hasLocalUsage)
        XCTAssertNil(empty.projectedFullCycleTokens)
        XCTAssertNil(empty.projectedFullCycleCostUSD)
        XCTAssertNil(empty.forecastConfidence)

        var unpriced = UsageTotals.zero
        unpriced.requestCount = 1
        unpriced.hasUnpricedUsage = true
        XCTAssertTrue(CycleUsageSummary(cycle: cycle, totals: unpriced, quality: .estimated).hasLocalUsage)
    }

    @MainActor
    func testCycleRebuildIgnoresEntriesBeforeFeatureTrackingStarted() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 100_000))
        let cycle = cycleRecord(
            id: "weekly-residual",
            accountKey: "claude:primary",
            app: .claude,
            start: day,
            end: Calendar.current.date(byAdding: .day, value: 1, to: day)!
        )
        let beforeTracking = UsageEntry(
            app: .claude,
            conversationKey: "claude:test",
            model: "claude-opus-4-8",
            speed: .standard,
            day: day,
            timestamp: day.addingTimeInterval(60),
            inputTokens: 40,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 4,
            costBreakdown: nil
        )
        var afterTracking = beforeTracking
        afterTracking.timestamp = day.addingTimeInterval(180)
        let aggregator = CycleUsageAggregator()
        aggregator.rebuild(
            exactEntries: [beforeTracking, afterTracking],
            cycles: [cycle],
            accountSegments: [QuotaCycleAccountSegment(
                id: "claude",
                accountKey: "claude:primary",
                app: .claude,
                startAt: day.addingTimeInterval(120),
                endAt: nil
            )]
        )
        let summary = try XCTUnwrap(aggregator.summaries(
            cycles: [cycle],
            kind: .weekly,
            app: .claude,
            now: cycle.endAt.addingTimeInterval(1)
        ).first)

        XCTAssertEqual(summary.totals.totalTokens, 40)
        XCTAssertEqual(summary.totals.costUSD, 4)
    }

    func testClaudeAssistantUsageMapsFastStandardAndMissingSpeed() throws {
        let fast = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-fast",
            speed: "fast"
        )))
        let standard = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-standard",
            speed: "standard"
        )))
        let unknown = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-unknown",
            speed: nil
        )))

        XCTAssertEqual(fast.speed, .fast)
        XCTAssertEqual(standard.speed, .standard)
        XCTAssertEqual(unknown.speed, .unknown)
        XCTAssertEqual(fast.cacheReadTokens, 30)
        XCTAssertEqual(fast.cacheCreationTokens, 40)
    }

    func testClaudeRepeatedStreamingLinesKeepSameMessageIdentity() throws {
        let first = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 10,
            stopReason: nil
        )))
        let completed = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 20,
            stopReason: "end_turn"
        )))
        var candidates: [String: ClaudeJSONLScanner.ParsedAssistant] = [:]
        ClaudeJSONLScanner.mergeCandidate(first, into: &candidates)
        ClaudeJSONLScanner.mergeCandidate(completed, into: &candidates)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates["msg-stream"]?.outputTokens, 20)
        XCTAssertEqual(candidates["msg-stream"]?.stopReason, "end_turn")
        XCTAssertFalse(ClaudeJSONLScanner.isComplete(first))
        XCTAssertTrue(ClaudeJSONLScanner.isComplete(completed))
    }

    func testClaudeCacheCreationTTLParsingPreservesAggregate() throws {
        let legacy = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-legacy-cache",
            speed: "standard",
            cacheCreationTokens: 40
        )))
        XCTAssertEqual(legacy.cacheCreationTokens, 40)
        XCTAssertEqual(legacy.cacheCreation5mTokens, 40)
        XCTAssertEqual(legacy.cacheCreation1hTokens, 0)

        let detailed = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-detailed-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 40,
            cacheCreation1hTokens: 60
        )))
        XCTAssertEqual(detailed.cacheCreationTokens, 100)
        XCTAssertEqual(detailed.cacheCreation5mTokens, 40)
        XCTAssertEqual(detailed.cacheCreation1hTokens, 60)

        let mismatched = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-mismatched-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 1,
            cacheCreation1hTokens: 30
        )))
        XCTAssertEqual(mismatched.cacheCreationTokens, 100)
        XCTAssertEqual(mismatched.cacheCreation5mTokens, 70)
        XCTAssertEqual(mismatched.cacheCreation1hTokens, 30)

        let clamped = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-clamped-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 20,
            cacheCreation1hTokens: 130
        )))
        XCTAssertEqual(clamped.cacheCreationTokens, 100)
        XCTAssertEqual(clamped.cacheCreation5mTokens, 0)
        XCTAssertEqual(clamped.cacheCreation1hTokens, 100)
    }

    func testCodexServiceTierTransitionsAndUnknownValue() {
        let transitions = ["default", "priority", "default"].map {
            CodexJSONLScanner.speed(fromServiceTier: $0)
        }

        XCTAssertEqual(transitions, [.standard, .fast, .standard])
        XCTAssertEqual(CodexJSONLScanner.speed(fromServiceTier: "future-tier"), .unknown)
        XCTAssertEqual(CodexJSONLScanner.speed(fromServiceTier: nil), .unknown)
    }

    func testCodexThreadSettingsFixtureReadsNestedPriorityTier() throws {
        let fixture: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": [
                    "model": "gpt-5.6-sol",
                    "service_tier": "priority",
                ],
            ],
        ]

        let settings = try XCTUnwrap(CodexJSONLScanner.threadSettings(from: fixture))

        XCTAssertEqual(settings.model, "gpt-5.6-sol")
        XCTAssertEqual(settings.speed, .fast)
    }

    func testCodexIncrementalStateKeepsFastTierAndCumulativeSignature() throws {
        let state = ScanFileState(
            mtime: 10,
            offset: 200,
            lastModel: "gpt-5.6-sol",
            lastServiceTier: .fast,
            lastCodexTotalUsageSignature: "100:20:0:30:5:150",
            conversationID: "thread-1",
            conversationCwd: "/tmp/project",
            conversationGitBranch: nil,
            conversationIsSidechain: nil,
            fallbackTitle: nil
        )

        let decoded = try JSONDecoder().decode(
            ScanFileState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.lastServiceTier, .fast)
        XCTAssertEqual(decoded.lastCodexTotalUsageSignature, state.lastCodexTotalUsageSignature)
    }

    func testCodexTruncationResetsTierModelAndDuplicateGuard() {
        var state = ScanFileState(
            mtime: 10,
            offset: 200,
            lastModel: "gpt-5.6-sol",
            lastServiceTier: .fast,
            lastCodexTotalUsageSignature: "signature",
            conversationID: "thread-1",
            conversationCwd: "/tmp/project",
            conversationGitBranch: nil,
            conversationIsSidechain: nil,
            fallbackTitle: nil
        )

        CodexJSONLScanner.resetForTruncation(&state)

        XCTAssertEqual(state.offset, 0)
        XCTAssertNil(state.lastModel)
        XCTAssertNil(state.lastServiceTier)
        XCTAssertNil(state.lastCodexTotalUsageSignature)
        XCTAssertEqual(state.conversationID, "thread-1")
    }

    func testCodexCumulativeUsageSignatureFiltersOnlyUnchangedTotals() {
        let total: [String: Any] = [
            "input_tokens": 100,
            "cached_input_tokens": 20,
            "output_tokens": 30,
            "reasoning_output_tokens": 5,
            "total_tokens": 150,
        ]
        var changed = total
        changed["output_tokens"] = 31

        XCTAssertEqual(
            CodexJSONLScanner.totalUsageSignature(total),
            CodexJSONLScanner.totalUsageSignature(total)
        )
        XCTAssertNotEqual(
            CodexJSONLScanner.totalUsageSignature(total),
            CodexJSONLScanner.totalUsageSignature(changed)
        )
        XCTAssertNil(CodexJSONLScanner.totalUsageSignature([:]))
    }

    func testFastPricingUsesExplicitTierRatesAndKeepsUnpricedAsNil() throws {
        let standard = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(standard.input, 0.5)
        XCTAssertEqual(standard.output, 3)
        XCTAssertEqual(standard.cacheRead, 0.05)
        XCTAssertEqual(standard.cacheCreation, 0.625)

        let claude = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheCreation: 1_000_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(claude.input, 10)
        XCTAssertEqual(claude.output, 50)
        XCTAssertEqual(claude.cacheRead, 1)
        XCTAssertEqual(claude.cacheCreation, 12.5)

        let codex = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .fast,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(codex.input, 1)
        XCTAssertEqual(codex.output, 6)
        XCTAssertEqual(codex.cacheRead, 0.1)
        XCTAssertEqual(codex.cacheCreation, 1.25)

        XCTAssertNil(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .fast,
            input: 272_001,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_001
        ))
        XCTAssertNil(Pricing.costBreakdown(
            app: .claude,
            model: "claude-future-model",
            speed: .fast,
            input: 1,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertNil(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .unknown,
            input: 1,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0)
        ))
    }

    func testLiteLLMDecoderSeparatesStandardAndOpenAIPriorityRates() throws {
        let data = Data(#"""
        {
          "gpt-future": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000030,
            "cache_read_input_token_cost": 0.0000005,
            "input_cost_per_token_priority": 0.000010,
            "output_cost_per_token_priority": 0.000060,
            "cache_read_input_token_cost_priority": 0.000001
          },
          "claude-future": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025,
            "input_cost_per_token_priority": 0.000010,
            "output_cost_per_token_priority": 0.000050
          }
        }
        """#.utf8)

        let decoded = try LiteLLMPricingDecoder.decode(data)
        XCTAssertEqual(decoded.standard["gpt-future"], ModelPrice(
            input: 5,
            output: 30,
            cacheRead: 0.5,
            cacheCreation: 0
        ))
        XCTAssertEqual(decoded.codexFast["gpt-future"], ModelPrice(
            input: 10,
            output: 60,
            cacheRead: 1,
            cacheCreation: 0
        ))
        XCTAssertNil(decoded.codexFast["claude-future"])
        XCTAssertTrue(decoded.claudeFast.isEmpty)
    }

    func testModelsDevDecoderReadsOfficialFastModeAndIgnoresReseller() throws {
        let data = Data(#"""
        {
          "anthropic": {
            "models": {
              "claude-opus-5": {
                "cost": {
                  "input": 5,
                  "output": 25,
                  "cache_read": 0.5,
                  "cache_write": 6.25
                },
                "experimental": {
                  "modes": {
                    "fast": {
                      "cost": {
                        "input": 10,
                        "output": 50,
                        "cache_read": 1,
                        "cache_write": 12.5
                      }
                    }
                  }
                }
              }
            }
          },
          "reseller": {
            "models": {
              "claude-opus-5": {
                "cost": {"input": 1, "output": 1},
                "experimental": {
                  "modes": {
                    "fast": {"cost": {"input": 2, "output": 2}}
                  }
                }
              }
            }
          }
        }
        """#.utf8)

        let decoded = try ModelsDevPricingDecoder.decode(data)
        XCTAssertEqual(decoded.standard["claude-opus-5"], ModelPrice(
            input: 5,
            output: 25,
            cacheRead: 0.5,
            cacheCreation: 6.25
        ))
        XCTAssertEqual(decoded.claudeFast["claude-opus-5"], ModelPrice(
            input: 10,
            output: 50,
            cacheRead: 1,
            cacheCreation: 12.5
        ))
        XCTAssertNil(decoded.codexFast["claude-opus-5"])
    }

    func testMissingPriceRefreshSkipsUnknownTierAndIntentionalInternalModel() {
        XCTAssertFalse(Pricing.needsRemotePriceRefresh(
            model: "future-model",
            app: .codex,
            speed: .unknown
        ))
        XCTAssertFalse(Pricing.needsRemotePriceRefresh(
            model: "codex-auto-review",
            app: .codex,
            speed: .standard
        ))
    }

    func testGPT55StandardLongContextProAndFastRates() throws {
        let standardShort = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_000
        ))
        XCTAssertEqual(standardShort.input, 0.5)
        XCTAssertEqual(standardShort.output, 3)
        XCTAssertEqual(standardShort.cacheRead, 0.05)

        let standardLong = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_001
        ))
        XCTAssertEqual(standardLong.input, 1)
        XCTAssertEqual(standardLong.output, 4.5)
        XCTAssertEqual(standardLong.cacheRead, 0.1)

        let fast = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .fast,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(fast.input, 1.25)
        XCTAssertEqual(fast.output, 7.5)
        XCTAssertEqual(fast.cacheRead, 0.125)

        let pro = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5-pro",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(pro.input, 3)
        XCTAssertEqual(pro.output, 18)
        XCTAssertEqual(pro.cacheRead, 3)
    }

    func testClaudeCacheCreationTTLUsesSeparateStandardAndFastRates() throws {
        let standard5m = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standard5m.cacheCreation, 0.25)

        let standard1h = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standard1h.cacheCreation, 0.4)

        let standardMixed = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standardMixed.cacheCreation, 0.65)

        let opus48Fast5m = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast5m.cacheCreation, 1.25)

        let opus48Fast1h = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast1h.cacheCreation, 2)

        let opus48Fast = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast.cacheCreation, 3.25)

        for model in ["claude-opus-4-7", "claude-opus-4-6"] {
            let historicalFast5m = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast5m.cacheCreation, 3.75)

            let historicalFast1h = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 0,
                cacheCreation1h: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast1h.cacheCreation, 6)

            let historicalFast = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 100_000,
                cacheCreation1h: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast.cacheCreation, 9.75)
        }

        let haikuStandard = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-haiku-4-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(haikuStandard.cacheCreation, 0.325)
    }

    @MainActor
    func testUnknownPriceStillAggregatesAsZeroCost() {
        let entry = UsageEntry(
            app: .codex,
            conversationKey: "codex:auto-review",
            model: "codex-auto-review",
            speed: .standard,
            day: Date(timeIntervalSince1970: 0),
            timestamp: Date(timeIntervalSince1970: 0),
            inputTokens: 100,
            outputTokens: 10,
            cacheReadTokens: 20,
            cacheCreationTokens: 0,
            costUSD: Pricing.cost(
                app: .codex,
                model: "codex-auto-review",
                speed: .standard,
                input: 100,
                output: 10,
                cacheRead: 20,
                cacheCreation: 0,
                at: Date(timeIntervalSince1970: 0)
            ),
            costBreakdown: nil
        )
        XCTAssertNil(entry.costUSD)

        let usage = UsageAggregator()
        usage.ingest([entry])
        let bucket = usage.snapshot().first
        XCTAssertEqual(bucket?.costUSD, 0)
        XCTAssertEqual(bucket?.inputTokens, 100)
        XCTAssertEqual(bucket?.outputTokens, 10)
        XCTAssertEqual(bucket?.cacheReadTokens, 20)
    }

    func testFastEquivalentTokensAreSeparateFromRawTokens() {
        var breakdown = UsageSpeedBreakdown()
        breakdown.add(speed: .standard, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")

        XCTAssertEqual(breakdown.summary, .mixed)
        XCTAssertEqual(breakdown.standard.totalTokens + breakdown.fast.totalTokens, 200)
        XCTAssertEqual(breakdown.fastBillingEquivalentTokens, 250)
        XCTAssertEqual(breakdown.fastMinimumMultiplier, 2.5)
        XCTAssertEqual(breakdown.fastMaximumMultiplier, 2.5)
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .codex, model: "gpt-5.6-sol", speed: .fast), 2.5)
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .claude, model: "claude-opus-4-7", speed: .fast), 6)

        var fastOnly = UsageSpeedBreakdown()
        fastOnly.add(speed: .fast, totals: usageTotals(tokens: 100), app: .claude, model: "claude-opus-4-8")
        XCTAssertEqual(fastOnly.summary, .fast)

        var unpriced = UsageSpeedBreakdown()
        unpriced.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-future")
        XCTAssertTrue(unpriced.hasUnpricedFastEquivalent)
        XCTAssertNil(unpriced.fastMinimumMultiplier)
    }

    @MainActor
    func testFastMultiplierHidesKnownRangeWhenUnknownModelsAreMixedIn() {
        var breakdown = UsageSpeedBreakdown()
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-future")

        XCTAssertEqual(breakdown.fast.totalTokens, 200)
        XCTAssertEqual(breakdown.fastBillingEquivalentTokens, 250)
        XCTAssertEqual(breakdown.fastMinimumMultiplier, 2.5)
        XCTAssertTrue(breakdown.hasUnpricedFastEquivalent)
        XCTAssertEqual(StatsFormatter.fastMultiplier(breakdown), "—")
    }

    @MainActor
    func testCodexFixtureScansTierTransitionsIncrementallyAndAfterTruncation() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessions = temporary.appendingPathComponent("sessions", isDirectory: true)
        let archived = temporary.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(conversationID).jsonl")
        )

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.map(\.speed), [.standard, .fast, .standard])
        XCTAssertEqual(first.entries.map(\.requestCount).reduce(0, +), 3)
        XCTAssertEqual(first.newState[conversationID]?.lastServiceTier, .standard)
        assertRollupsMatch(entries: first.entries, seeds: first.conversationSeeds)

        try appendJSONL("""
        {"timestamp":"2026-07-16T00:00:09Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T00:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}
        {"timestamp":"2026-07-16T00:00:11Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":70,"reasoning_output_tokens":10,"total_tokens":570},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":25,"reasoning_output_tokens":3,"total_tokens":175}}}}
        """, to: file)

        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.speed, .fast)
        XCTAssertEqual(second.newState[conversationID]?.lastServiceTier, .fast)

        let unchanged = await CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.linesParsed, 0)

        let truncated = """
        {"timestamp":"2026-07-16T02:00:00Z","type":"session_meta","payload":{"id":"\(conversationID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T02:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
        {"timestamp":"2026-07-16T02:00:02Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-terra","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T02:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55}}}}

        """
        try Data(truncated.utf8).write(to: file, options: [.atomic])

        let afterTruncation = await CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(afterTruncation.entries.count, 1)
        XCTAssertEqual(afterTruncation.entries.first?.model, "gpt-5.6-terra")
        XCTAssertEqual(afterTruncation.entries.first?.speed, .fast)
        XCTAssertEqual(afterTruncation.newState[conversationID]?.lastModel, "gpt-5.6-terra")
    }

    @MainActor
    func testClaudeFixtureDefersPartialLineDeduplicatesFilesAndResumesByOffset() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let projects = temporary.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let mainFile = try copyFixture(
            named: "claude-fast-scan",
            to: container.appendingPathComponent("claude-session.jsonl")
        )
        let duplicateLine = try fixtureLine(named: "claude-fast-scan", containing: "\"msg-standard\"")
        try Data("\(duplicateLine)\n".utf8).write(
            to: container.appendingPathComponent("duplicate.jsonl"),
            options: [.atomic]
        )
        let emptyIndex = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let first = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: projects,
            conversationIndex: emptyIndex
        )
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertEqual(first.entries.filter { $0.speed == .standard }.count, 1)
        XCTAssertEqual(first.entries.filter { $0.speed == .fast }.count, 1)
        XCTAssertEqual(first.entries.filter { $0.speed == .unknown }.count, 1)
        XCTAssertFalse(first.newSeenIds.contains("msg-stream"))
        XCTAssertEqual(first.newSeenIds.filter { $0 == "msg-standard" }.count, 1)
        assertRollupsMatch(entries: first.entries, seeds: first.conversationSeeds)

        try appendJSONL(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 40,
            stopReason: "end_turn",
            cacheCreationTokens: 50,
            cacheCreation5mTokens: 20,
            cacheCreation1hTokens: 30,
            sessionID: "claude-fixture-session"
        ), to: mainFile)

        let second = ClaudeJSONLScanner.scan(
            previous: first.newState,
            seenMessageIds: first.newSeenIds,
            root: projects,
            conversationIndex: emptyIndex
        )
        let streamed = try XCTUnwrap(second.entries.first)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(streamed.speed, .fast)
        XCTAssertEqual(streamed.cacheCreationTokens, 50)
        XCTAssertEqual(streamed.costBreakdown?.cacheCreation, Decimal(plainString: "0.00085"))
        XCTAssertEqual(second.newSeenIds.filter { $0 == "msg-stream" }.count, 1)

        let unchanged = ClaudeJSONLScanner.scan(
            previous: second.newState,
            seenMessageIds: second.newSeenIds,
            root: projects,
            conversationIndex: emptyIndex
        )
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.linesParsed, 0)
    }

    func testFastCacheSchemaVersionsAreUpgradedTogether() {
        XCTAssertEqual(ScanState.currentVersion, 11)
        XCTAssertEqual(UsageRollupPayload.currentVersion, 8)
        XCTAssertEqual(ConversationRollupPayload.currentVersion, 5)
        XCTAssertEqual(QuotaCyclePayload.currentVersion, 4)
        XCTAssertEqual(CycleUsageRollupPayload.currentVersion, 3)
        XCTAssertEqual(PricingCatalogCachePayload.currentVersion, 2)
        XCTAssertEqual(Pricing.fingerprint(knownUsage: []).count, 64)
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

    private func cycleRecord(
        id: String,
        accountKey: String,
        app: UsageApp,
        start: Date,
        end: Date,
        usedPercent: Double = 25
    ) -> QuotaCycleRecord {
        QuotaCycleRecord(
            id: id,
            accountKey: accountKey,
            app: app,
            limitID: "weekly",
            limitKind: .weekly,
            startAt: start,
            endAt: end,
            scheduledEndAt: end,
            firstSampleAt: start,
            lastSampleAt: end,
            latestUsedPercent: usedPercent,
            allowanceSegments: [QuotaCycleAllowanceSegment(
                id: "\(id)-allowance",
                startAt: start,
                endAt: nil,
                baselineUsedPercent: 0,
                latestUsedPercent: usedPercent,
                maximumUsedPercent: usedPercent,
                firstSampleAt: start,
                lastSampleAt: end,
                startReason: .initial
            )],
            source: .api,
            boundaryQuality: .observed
        )
    }

    private func claudeAssistantLine(
        messageID: String,
        speed: String?,
        outputTokens: Int = 20,
        stopReason: String? = "end_turn",
        cacheCreationTokens: Int = 40,
        cacheCreation5mTokens: Int? = nil,
        cacheCreation1hTokens: Int? = nil,
        sessionID: String = "session-1"
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": outputTokens,
            "cache_read_input_tokens": 30,
            "cache_creation_input_tokens": cacheCreationTokens,
        ]
        if let speed { usage["speed"] = speed }
        if cacheCreation5mTokens != nil || cacheCreation1hTokens != nil {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": cacheCreation5mTokens ?? 0,
                "ephemeral_1h_input_tokens": cacheCreation1hTokens ?? 0,
            ]
        }
        var message: [String: Any] = [
            "id": messageID,
            "model": "claude-opus-4-8",
            "usage": usage,
        ]
        if let stopReason { message["stop_reason"] = stopReason }
        let root: [String: Any] = [
            "type": "assistant",
            "sessionId": sessionID,
            "cwd": "/tmp/project",
            "timestamp": "2026-07-16T00:00:00Z",
            "message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copyFixture(named name: String, to destination: URL) throws -> URL {
        let source = try XCTUnwrap(
            Bundle(for: QuotaParsingTests.self).url(forResource: name, withExtension: "jsonl")
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func fixtureLine(named name: String, containing needle: String) throws -> String {
        let source = try XCTUnwrap(
            Bundle(for: QuotaParsingTests.self).url(forResource: name, withExtension: "jsonl")
        )
        let text = try String(contentsOf: source, encoding: .utf8)
        return try XCTUnwrap(text.split(separator: "\n").map(String.init).first { $0.contains(needle) })
    }

    private func appendJSONL(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var value = text
        if !value.hasSuffix("\n") { value.append("\n") }
        try handle.write(contentsOf: Data(value.utf8))
    }

    @MainActor
    private func assertRollupsMatch(entries: [UsageEntry], seeds: [ConversationSeed]) {
        let usage = UsageAggregator()
        let conversations = ConversationAggregator()
        usage.ingest(entries)
        conversations.ingest(entries: entries, seeds: seeds)
        let usageBuckets = usage.snapshot()
        let conversationBuckets = conversations.snapshot().buckets

        for app in UsageApp.allCases {
            for model in Set(entries.filter { $0.app == app }.map(\.model)) {
                for speed in UsageSpeed.allCases {
                    let daily = usageBuckets.filter { $0.app == app && $0.model == model && $0.speed == speed }
                    let detail = conversationBuckets.filter { $0.app == app && $0.model == model && $0.speed == speed }
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.inputTokens }, detail.reduce(0) { $0 + $1.inputTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.outputTokens }, detail.reduce(0) { $0 + $1.outputTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.cacheReadTokens }, detail.reduce(0) { $0 + $1.cacheReadTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.cacheCreationTokens }, detail.reduce(0) { $0 + $1.cacheCreationTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.requestCount }, detail.reduce(0) { $0 + $1.requestCount })
                    XCTAssertEqual(daily.reduce(Decimal.zero) { $0 + $1.costUSD }, detail.reduce(Decimal.zero) { $0 + $1.costUSD })
                }
            }
        }
    }

    private func usageTotals(tokens: Int) -> UsageTotals {
        UsageTotals(
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0,
            requestCount: 1,
            hasUnpricedUsage: false
        )
    }
}
