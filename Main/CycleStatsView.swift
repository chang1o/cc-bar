import Charts
import SwiftUI

struct CycleStatsView: View {
    @Environment(AppState.self) private var appState

    let canvasWidth: CGFloat

    /// 历史曲线当前展示的周期类型（Codex / Claude 两个面板共用）。
    @State private var historyKind: QuotaLimitKind = .weekly
    /// 每个面板独立的悬浮吸附时间点。
    @State private var selectedEndAt: [UsageApp: Date?] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if appState.usageService.isCycleRebuilding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Rebuilding cycle history…", "正在补算周期历史…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            currentCyclesSection
            historySection
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("Cycle usage", "周期用量"))
                .font(.system(size: 18, weight: .semibold))
                .kerning(-0.2)
            Text(tr(
                "See actual Tokens and API-equivalent cost for each cycle, with an estimate at full use.",
                "查看每个周期实际使用的 Tokens、API 等值费用，以及用满时的预估。"
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 当前周期

    /// Codex / Claude × 5 小时 / 周 共 4 张 KPI 卡一行，对齐 Stats 首页 KPI 行。
    private var currentCyclesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Current cycles", "当前周期"))
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 12) {
                currentCycleKpiCard(app: .codex, kind: .fiveHour)
                currentCycleKpiCard(app: .codex, kind: .weekly)
                currentCycleKpiCard(app: .claude, kind: .fiveHour)
                currentCycleKpiCard(app: .claude, kind: .weekly)
            }
        }
    }

    /// KPI 卡：6pt 识别色点 + 服务/周期标签 → 整周期预估 Tokens·费用大字 →
    /// 已用辅助行 → 迷你进度条 → 倒计时。空态只保留标签与一句引导。
    private func currentCycleKpiCard(app: UsageApp, kind: QuotaLimitKind) -> some View {
        Group {
            if let summary = currentSummary(app: app, kind: kind) {
                cycleKpiBody(summary, app: app, kind: kind)
            } else {
                cycleKpiEmptyState(app: app, kind: kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: 152)
        .ccPanel(cornerRadius: 10)
    }

    /// 卡主体：标签行 → 用满预估大字 → 已用辅助行 → 迷你进度条 → 倒计时。
    private func cycleKpiBody(
        _ summary: CycleUsageSummary,
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> some View {
        let usedPercent = max(0, summary.cycle.latestUsedPercent)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ServiceMark(color: app.tintColor, size: 6, cornerRadius: 1.5)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let confidence = summary.forecastConfidence {
                    Text(forecastConfidenceText(confidence))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Text(fullUseLine(summary))
                .font(.system(size: 24, weight: .semibold))
                .kerning(-0.5)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 2)

            Text(
                "\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage)) · \(String(format: "%.1f%%", usedPercent))"
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            ProgressBar(
                value: usedPercent / 100,
                tint: statusColor(remainingPercent: 100 - usedPercent, tint: app.tintColor),
                height: 4
            )
            .padding(.top, 3)

            Spacer(minLength: 0)

            ResetTimeText(resetsAt: summary.cycle.endAt)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    /// 空态卡：标签行固定在顶部，下方提示内容在剩余空间垂直居中。
    private func cycleKpiEmptyState(app: UsageApp, kind: QuotaLimitKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ServiceMark(color: app.tintColor, size: 6, cornerRadius: 1.5)
                Text("\(app.displayName) · \(cycleKindShort(kind))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(hasAccount(app)
                     ? tr("Waiting for the current cycle", "等待当前周期")
                     : tr("Account not detected", "未检测到账号"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(hasAccount(app)
                 ? tr(
                    "A successful quota refresh will establish this reset cycle.",
                    "额度刷新成功后会建立该重置周期。"
                 )
                 : tr(
                    "Connect this service and refresh quota to start recording cycles.",
                    "连接该服务并刷新额度后开始记录周期。"
                 ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }

    // MARK: - 历史周期曲线

    /// Codex / Claude 各一个面板，面板内切换 5 小时 / 周，
    /// 曲线为各已完成周期的用满预估费用，悬浮显示周期明细。
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Completed cycles", "历史周期"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(tr(
                        "Full-use estimate per finished cycle; hollow points are actual-only cycles without an estimate.",
                        "每个已结束周期的用满预估曲线；空心点表示只有实际用量、没有预估依据。"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("", selection: $historyKind) {
                    Text(tr("5-hour", "5 小时")).tag(QuotaLimitKind.fiveHour)
                    Text(tr("Weekly", "周")).tag(QuotaLimitKind.weekly)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: historyKind) { _, _ in selectedEndAt = [:] }
            }

            ForEach([UsageApp.codex, .claude], id: \.self) { app in
                if !completedSummaries(app: app, kind: .fiveHour).isEmpty
                    || !completedSummaries(app: app, kind: .weekly).isEmpty {
                    historyChartPanel(app: app, panelWidth: max(0, canvasWidth - 40))
                }
            }

            Text(tr(
                "Actual Tokens and cost include only local logs found by CCBar. Estimates use provider-reported percentage increases observed by CCBar; cycles without an observed increase remain actual-only, and estimates are not official limits.",
                "实际 Tokens 与费用只包含 CCBar 能读取到的本机日志。预估只使用 CCBar 实际观察到的服务端比例增量；未观察到增长的周期仅保留实际用量，预估也不代表官方额度。"
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 每服务一个面板：服务名 + 曲线（或空态），周期类型由历史区统一切换。
    private func historyChartPanel(app: UsageApp, panelWidth: CGFloat) -> some View {
        let summaries = completedSummaries(app: app, kind: historyKind)
        let hasActualOnly = summaries.contains {
            $0.projectedFullCycleCostUSD == nil && $0.totals.costUSD > 0
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ServiceMark(color: app.tintColor, size: 9, cornerRadius: 2.2)
                Text(app.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if hasActualOnly {
                    Circle()
                        .stroke(app.tintColor, lineWidth: 1.4)
                        .frame(width: 7, height: 7)
                    Text(tr("Actual only · no estimate", "仅实际 · 无预估"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            if summaries.isEmpty {
                Text(tr("No completed cycles yet", "暂无已结束周期"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 210)
            } else {
                historyChart(summaries: summaries, app: app)
                    .frame(height: 210)
            }
        }
        .padding(16)
        .frame(width: panelWidth, alignment: .topLeading)
        .ccPanel(cornerRadius: 12)
    }

    /// 周期曲线：有预估的周期以 LineMark + 实心 PointMark 展示；只有实际用量的周期
    /// 以实际费用定位空心点，不接入预估趋势线。悬浮吸附最近数据点并显示周期明细。
    private func historyChart(summaries: [CycleUsageSummary], app: UsageApp) -> some View {
        Chart {
            ForEach(summaries) { summary in
                if let cost = projectedCost(summary) {
                    LineMark(
                        x: .value("Time", summary.cycle.endAt),
                        y: .value("Cost", cost)
                    )
                    .foregroundStyle(app.tintColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Time", summary.cycle.endAt),
                        y: .value("Cost", cost)
                    )
                    .foregroundStyle(app.tintColor)
                    .symbolSize(26)
                } else if summary.totals.costUSD > 0 {
                    PointMark(
                        x: .value("Time", summary.cycle.endAt),
                        y: .value("Actual cost", actualCost(summary))
                    )
                    .foregroundStyle(app.tintColor)
                    .symbol {
                        Circle()
                            .stroke(app.tintColor, lineWidth: 1.6)
                            .frame(width: 8, height: 8)
                    }
                }
            }

            if let selected = selectedSummary(at: selectedEndAt[app] ?? nil, in: summaries) {
                RuleMark(x: .value("Time", selected.cycle.endAt))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                    ) {
                        historyTooltip(selected)
                    }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedEndAt[app] ?? nil },
            set: { selectedEndAt[app] = $0 }
        ))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(StatsFormatter.axisCost(Decimal(doubleValue)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    /// 悬浮明细卡：时间范围（周周期附带天数）· 预估 Tokens/费用 · 已用与百分比 · 重置 ×N。
    private func historyTooltip(_ summary: CycleUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tooltipTimeLine(summary))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("\(tr("Estimate", "预估")) \(fullUseLine(summary))")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text(
                "\(tr("Used", "已用")) \(StatsFormatter.compactToken(summary.totals.totalTokens)) · \(StatsFormatter.tierCostWhole(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage)) · \(historyObservationText(summary))"
            )
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            if summary.cycle.extraResetCount > 0 {
                Text(extraResetText(summary.cycle.extraResetCount))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    /// 悬浮首行：时间段，周周期附带「N 天」（Codex 周可能 2-3 天就重置）。
    private func tooltipTimeLine(_ summary: CycleUsageSummary) -> String {
        let period = periodText(summary.cycle)
        if let days = cycleDurationDays(summary) {
            return "\(period) · \(String(format: tr("%d days", "%d 天"), days))"
        }
        return period
    }

    /// 周周期窗口天数（四舍五入），5 小时周期不展示。
    private func cycleDurationDays(_ summary: CycleUsageSummary) -> Int? {
        guard summary.cycle.limitKind == .weekly else { return nil }
        let seconds = summary.cycle.endAt.timeIntervalSince(summary.cycle.startAt)
        return max(1, Int((seconds / 86_400).rounded()))
    }

    /// 用满预估费用转 Double；无依据时返回 nil，避免把缺失预估画成 0。
    private func projectedCost(_ summary: CycleUsageSummary) -> Double? {
        guard let cost = summary.projectedFullCycleCostUSD else { return nil }
        return NSDecimalNumber(decimal: cost).doubleValue
    }

    /// 无预估周期以实际费用定位空心点，不与预估趋势线相连。
    private func actualCost(_ summary: CycleUsageSummary) -> Double {
        NSDecimalNumber(decimal: summary.totals.costUSD).doubleValue
    }

    /// 悬浮时间点吸附到 endAt 最近的周期。
    private func selectedSummary(
        at date: Date?,
        in summaries: [CycleUsageSummary]
    ) -> CycleUsageSummary? {
        guard let date else { return nil }
        return summaries.min {
            abs($0.cycle.endAt.timeIntervalSince(date))
                < abs($1.cycle.endAt.timeIntervalSince(date))
        }
    }

    // MARK: - 数据

    private func currentSummary(
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> CycleUsageSummary? {
        guard let accountKey = accountKey(for: app) else { return nil }
        return summaries(kind: kind, app: app)
            .filter { $0.cycle.isCurrent() && $0.cycle.accountKey == accountKey }
            .sorted { lhs, rhs in
                let lhsLastSample = lhs.cycle.lastSampleAt ?? .distantPast
                let rhsLastSample = rhs.cycle.lastSampleAt ?? .distantPast
                if lhsLastSample != rhsLastSample { return lhsLastSample > rhsLastSample }
                if lhs.cycle.boundaryQuality != rhs.cycle.boundaryQuality {
                    return lhs.cycle.boundaryQuality == .observed
                }
                return lhs.cycle.endAt > rhs.cycle.endAt
            }
            .first
    }

    private func completedSummaries(
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> [CycleUsageSummary] {
        summaries(kind: kind, app: app).filter {
            $0.cycle.isComplete() && $0.totals.totalTokens > 0
        }
    }

    private func summaries(
        kind: QuotaLimitKind,
        app: UsageApp?
    ) -> [CycleUsageSummary] {
        appState.usageService.cycleAggregator.summaries(
            cycles: appState.quotaCycles.records,
            kind: kind,
            app: app
        )
    }

    private func accountKey(for app: UsageApp) -> String? {
        switch app {
        case .codex:
            guard appState.codexAccount != nil else { return nil }
            return QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
        case .claude:
            guard appState.claudeAccount != nil else { return nil }
            return QuotaHistoryAccountKey.claudePrimary(email: appState.claudeAccount?.email)
        case .pi, .opencode:
            return nil
        }
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
    }
}

// MARK: - 周期页共享的纯函数与子视图

/// 周期类型短标签：5 小时 / 周，用于 KPI 卡标签与历史行。
private func cycleKindShort(_ kind: QuotaLimitKind) -> String {
    switch kind {
    case .fiveHour: return tr("5-hour", "5 小时")
    case .weekly: return tr("Weekly", "周")
    default: return tr("Cycle", "周期")
    }
}

/// KPI 卡主数字：用满预估 `Tokens · 费用`，无依据的一侧显示 `—`。
private func fullUseLine(_ summary: CycleUsageSummary) -> String {
    let tokens = summary.projectedFullCycleTokens
        .map { StatsFormatter.compactToken($0) } ?? "—"
    let cost = summary.projectedFullCycleCostUSD
        .map { StatsFormatter.tierCostWhole($0, hasUnpricedUsage: false) } ?? "—"
    return "\(tokens) · \(cost)"
}

private func historyObservationText(_ summary: CycleUsageSummary) -> String {
    let observed = summary.forecastObservedPercent
    guard observed > 0 else {
        return tr("No observed increase", "未观察到增量")
    }
    return String(format: "%.1f%%", observed)
}

private func forecastConfidenceText(_ confidence: CycleForecastConfidence) -> String {
    switch confidence {
    case .early: return tr("Early estimate", "早期估算")
    case .rough: return tr("Rough estimate", "粗略估算")
    case .reference: return tr("Reference", "参考")
    case .reliable: return tr("More reliable", "较可靠")
    }
}

private func extraResetText(_ count: Int) -> String {
    String(format: tr("Extra reset ×%d", "重置 ×%d"), count)
}

private func periodText(_ cycle: QuotaCycleRecord) -> String {
    "\(periodFormatter.string(from: cycle.startAt)) – \(periodFormatter.string(from: cycle.endAt))"
}

private let periodFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MM-dd HH:mm"
    return formatter
}()
