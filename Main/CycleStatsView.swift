import SwiftUI

struct CycleStatsView: View {
    @Environment(AppState.self) private var appState

    let canvasWidth: CGFloat

    @State private var historyTab: HistoryTab = .codexFiveHour
    @State private var visibleCounts: [HistoryTab: Int] = [:]

    /// 当前周期卡：达到该宽度时同一服务的 5 小时 / 周周期左右并排，更窄时单列堆叠。
    private static let twoColumnWidth: CGFloat = 720
    private static let historyPageSize = 8

    /// 历史区一次只展示一个「服务 × 周期类型」组合，避免 4 张同构表堆屏。
    private enum HistoryTab: String, CaseIterable, Identifiable, Hashable {
        case codexFiveHour
        case codexWeekly
        case claudeFiveHour
        case claudeWeekly

        var id: String { rawValue }

        var app: UsageApp {
            switch self {
            case .codexFiveHour, .codexWeekly: return .codex
            case .claudeFiveHour, .claudeWeekly: return .claude
            }
        }

        var kind: QuotaLimitKind {
            switch self {
            case .codexFiveHour, .claudeFiveHour: return .fiveHour
            case .codexWeekly, .claudeWeekly: return .weekly
            }
        }
    }

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

            currentCycleGrid
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

    /// Codex → Claude 两行、5 小时 → 周周期两列的卡片网格。
    /// 行内比同一服务的两个周期，列内比两个服务的同一周期，两个方向都能直接对照。
    private var currentCycleGrid: some View {
        let isTwoColumn = canvasWidth >= Self.twoColumnWidth

        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("Current cycles", "当前周期"))
                .font(.system(size: 13, weight: .semibold))

            if isTwoColumn {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        currentCycleCard(app: .codex, kind: .fiveHour)
                        currentCycleCard(app: .codex, kind: .weekly)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        currentCycleCard(app: .claude, kind: .fiveHour)
                        currentCycleCard(app: .claude, kind: .weekly)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    currentCycleCard(app: .codex, kind: .fiveHour)
                    currentCycleCard(app: .codex, kind: .weekly)
                    currentCycleCard(app: .claude, kind: .fiveHour)
                    currentCycleCard(app: .claude, kind: .weekly)
                }
            }
        }
    }

    private func currentCycleCard(app: UsageApp, kind: QuotaLimitKind) -> some View {
        VStack(spacing: 0) {
            // 顶部 2pt 服务识别色边,只做品牌识别,不参与额度着色。
            Rectangle()
                .fill(app.tintColor)
                .frame(height: 2)

            Group {
                if let summary = currentSummary(app: app, kind: kind) {
                    currentCycleBody(summary, app: app, kind: kind)
                } else {
                    currentCycleEmptyState(app: app, kind: kind)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 172, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ccPanel(cornerRadius: 12)
    }

    private func currentCycleBody(
        _ summary: CycleUsageSummary,
        app: UsageApp,
        kind: QuotaLimitKind
    ) -> some View {
        let usedPercent = max(0, min(100, summary.cycle.latestUsedPercent))

        return VStack(alignment: .leading, spacing: 0) {
            cardHeader(app: app, kind: kind, resetsAt: summary.cycle.endAt)

            Spacer(minLength: 12)

            // 「本机实际」与「已用比例」共用一行 label,下一行才是各自的主数值。
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Local actual", "本机实际"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: tr("Used %.1f%%", "已用 %.1f%%"), usedPercent))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(StatsFormatter.compactToken(summary.totals.totalTokens))
                    .font(.system(size: 20, weight: .semibold))
                    .kerning(-0.25)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Tokens")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                Text(StatsFormatter.tierCost(
                    summary.totals.costUSD,
                    hasUnpricedUsage: summary.totals.hasUnpricedUsage
                ))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .padding(.bottom, 10)

            // 填充段 = 本机实际,整条 = 用满预估;填充比例即官方已用比例。
            // 「用了多少 / 用了几成 / 用满是多少」由同一条同时表达,不用心算。
            ProgressBar(
                value: usedPercent / 100,
                tint: statusColor(remainingPercent: 100 - usedPercent, tint: app.tintColor),
                height: 6
            )
            .padding(.bottom, 10)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tr("Full-use estimate", "用满预估"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(forecastTokenText(summary.projectedFullCycleTokens))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("Tokens")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

                Text(forecastCostText(summary.projectedFullCycleCostUSD))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 10)

            Text(forecastContextText(summary))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func currentCycleEmptyState(app: UsageApp, kind: QuotaLimitKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(app: app, kind: kind, resetsAt: nil)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 5) {
                Text(hasAccount(app)
                     ? tr("Waiting for the current cycle", "等待当前周期")
                     : tr("Account not detected", "未检测到账号"))
                    .font(.system(size: 12.5, weight: .medium))
                Text(hasAccount(app)
                     ? tr(
                        "A successful quota refresh will establish this reset cycle.",
                        "额度刷新成功后会建立该重置周期。"
                     )
                     : tr(
                        "Connect this service and refresh quota to start recording cycles.",
                        "连接该服务并刷新额度后开始记录周期。"
                     ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func cardHeader(app: UsageApp, kind: QuotaLimitKind, resetsAt: Date?) -> some View {
        HStack(spacing: 7) {
            ServiceMark(color: app.tintColor, size: 9, cornerRadius: 2.2)
            Text(app.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(cycleKindTitle(kind, plural: false))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            if let resetsAt {
                ResetTimeText(resetsAt: resetsAt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 历史周期

    private var historySection: some View {
        let panelWidth = max(0, canvasWidth - 40)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Completed cycles", "历史周期"))
                    .font(.system(size: 13, weight: .semibold))
                Text(tr(
                    "Pick a provider and cycle length to compare finished cycles one list at a time.",
                    "选择服务与周期类型，逐个对比已结束周期的额度、实际用量和用满预估。"
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }

            Picker("", selection: $historyTab) {
                ForEach(HistoryTab.allCases) { tab in
                    Text(historyTabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460, alignment: .leading)

            historyPanel(panelWidth: panelWidth)

            Text(tr(
                "Quota used is the highest provider-reported usage in the initial allowance plus any extra-reset allowances. Actual Tokens and cost include only local logs found by CCBar; estimates are not official limits, and unobserved cycles are not invented.",
                "额度已用取初始额度与各福利重置额度段内服务端记录到的最高比例。实际 Tokens 与费用只包含 CCBar 能读取到的本机日志；预估不代表官方额度，也不会补造未观察周期。"
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyPanel(panelWidth: CGFloat) -> some View {
        let tab = historyTab
        let rows = completedSummaries(app: tab.app, kind: tab.kind)
        let visible = visibleCount(tab)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ServiceMark(color: tab.app.tintColor, size: 9, cornerRadius: 2.2)
                Text(tab.app.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(cycleKindTitle(tab.kind, plural: true))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: tr("%d cycles", "%d 个周期"), rows.count))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if rows.isEmpty {
                Text(tr("No completed cycles yet", "暂无已结束周期"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                historyTable(
                    rows: Array(rows.prefix(visible)),
                    tableWidth: max(0, panelWidth - 32)
                )

                if rows.count > visible {
                    Button(String(
                        format: tr("Show %d more cycles", "再显示 %d 个周期"),
                        Self.historyPageSize
                    )) {
                        visibleCounts[tab] = visible + Self.historyPageSize
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .frame(width: panelWidth, alignment: .topLeading)
        .ccPanel(cornerRadius: 12)
    }

    /// 四列表：周期 / 额度已用 / 实际 / 用满预估。
    /// 「实际」与「用满预估」各自把 Tokens 与费用上下堆叠成一格,
    /// 同列上下对照,不必横跨半屏找对应数字。
    private func historyTable(
        rows: [CycleUsageSummary],
        tableWidth: CGFloat
    ) -> some View {
        let horizontalSpacing: CGFloat = 10
        let usableWidth = max(0, tableWidth - horizontalSpacing * 3)
        let periodWidth = max(150, usableWidth * 0.34)
        let quotaWidth = max(88, usableWidth * 0.16)
        let metricWidth = max(96, (usableWidth - periodWidth - quotaWidth) / 2)

        return Grid(alignment: .leading, horizontalSpacing: horizontalSpacing, verticalSpacing: 0) {
            GridRow {
                tableHeader(tr("Period", "周期"), width: periodWidth)
                tableHeader(tr("Quota used", "额度已用"), width: quotaWidth, alignment: .trailing)
                tableHeader(
                    tr("Actual Tokens / cost", "实际 Tokens / 费用"),
                    width: metricWidth,
                    alignment: .trailing
                )
                tableHeader(
                    tr("Full-use Tokens / cost", "用满 Tokens / 费用"),
                    width: metricWidth,
                    alignment: .trailing
                )
            }
            .padding(.bottom, 7)

            Divider().gridCellColumns(4)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, summary in
                historyRow(
                    summary,
                    periodWidth: periodWidth,
                    quotaWidth: quotaWidth,
                    metricWidth: metricWidth
                )
                .padding(.vertical, 9)

                if index < rows.count - 1 {
                    Divider().gridCellColumns(4)
                }
            }
        }
    }

    private func historyRow(
        _ summary: CycleUsageSummary,
        periodWidth: CGFloat,
        quotaWidth: CGFloat,
        metricWidth: CGFloat
    ) -> some View {
        let usedPercent = max(0, summary.cycle.reportedUsedPercent)

        return GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(periodText(summary.cycle))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(historyMetadataText(summary))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: periodWidth, alignment: .leading)

            // 迷你条让「哪个周期烧满了、哪个没用完」一眼可见。
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f%%", usedPercent))
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                ProgressBar(
                    value: usedPercent / 100,
                    tint: statusColor(
                        remainingPercent: 100 - usedPercent,
                        tint: summary.cycle.app.tintColor
                    ),
                    height: 3
                )
            }
            .frame(width: quotaWidth, alignment: .trailing)

            stackedMetric(
                primary: StatsFormatter.compactToken(summary.totals.totalTokens),
                secondary: StatsFormatter.tierCost(
                    summary.totals.costUSD,
                    hasUnpricedUsage: summary.totals.hasUnpricedUsage
                ),
                width: metricWidth
            )

            stackedMetric(
                primary: forecastTokenText(summary.projectedFullCycleTokens),
                secondary: forecastCostText(summary.projectedFullCycleCostUSD),
                width: metricWidth
            )
        }
    }

    private func stackedMetric(primary: String, secondary: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(primary)
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.74)
            Text(secondary)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .frame(width: width, alignment: .trailing)
    }

    private func tableHeader(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: alignment)
            .frame(minHeight: 26)
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
            return QuotaHistoryAccountKey.claudePrimary()
        case .pi, .opencode:
            return nil
        }
    }

    private func hasAccount(_ app: UsageApp) -> Bool {
        accountKey(for: app) != nil
    }

    private func visibleCount(_ tab: HistoryTab) -> Int {
        visibleCounts[tab] ?? Self.historyPageSize
    }

    // MARK: - 文案

    private func historyTabTitle(_ tab: HistoryTab) -> String {
        switch tab {
        case .codexFiveHour: return tr("Codex · 5H", "Codex · 5 小时")
        case .codexWeekly: return tr("Codex · Weekly", "Codex · 周")
        case .claudeFiveHour: return tr("Claude · 5H", "Claude · 5 小时")
        case .claudeWeekly: return tr("Claude · Weekly", "Claude · 周")
        }
    }

    private func cycleKindTitle(_ kind: QuotaLimitKind, plural: Bool) -> String {
        switch (kind, plural) {
        case (.fiveHour, false): return tr("5-hour cycle", "5 小时周期")
        case (.weekly, false): return tr("Weekly cycle", "周周期")
        case (.fiveHour, true): return tr("5-hour cycles", "5 小时周期")
        case (.weekly, true): return tr("Weekly cycles", "周周期")
        default: return tr("Reset cycle", "重置周期")
        }
    }

    private func forecastContextText(_ summary: CycleUsageSummary) -> String {
        var parts: [String] = []
        if summary.cycle.firstSampleAt != nil {
            parts.append(String(format: tr(
                "Estimate based on %.1f%%",
                "预估依据 %.1f%%"
            ), summary.forecastObservedPercent))
        }
        if let confidence = summary.forecastConfidence {
            parts.append(confidenceText(confidence))
        } else {
            parts.append(tr("No estimate basis", "暂无预估依据"))
        }
        if let quality = qualityText(summary.quality) {
            parts.append(quality)
        }
        if summary.cycle.extraResetCount > 0 {
            parts.append(extraResetText(summary.cycle.extraResetCount))
        }
        return parts.joined(separator: " · ")
    }

    private func historyMetadataText(_ summary: CycleUsageSummary) -> String {
        var parts: [String] = []
        if let confidence = summary.forecastConfidence {
            parts.append(confidenceText(confidence))
        } else {
            parts.append(tr("No estimate", "暂无预估"))
        }
        if let quality = qualityText(summary.quality) {
            parts.append(quality)
        }
        if summary.cycle.extraResetCount > 0 {
            parts.append(extraResetText(summary.cycle.extraResetCount))
        }
        return parts.joined(separator: " · ")
    }

    private func confidenceText(_ confidence: CycleForecastConfidence) -> String {
        switch confidence {
        case .early: return tr("Early estimate", "早期估算")
        case .rough: return tr("Rough estimate", "粗略估算")
        case .reference: return tr("Reference estimate", "参考估算")
        case .reliable: return tr("More reliable", "较可靠")
        }
    }

    private func qualityText(_ quality: CycleUsageQuality) -> String? {
        switch quality {
        case .exact: return nil
        case .estimated: return tr("Estimated data", "估算数据")
        case .incomplete: return tr("Partial data", "数据不完整")
        }
    }

    private func forecastCostText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return "≈\(StatsFormatter.tierCost(value, hasUnpricedUsage: false))"
    }

    private func forecastTokenText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "≈\(StatsFormatter.compactToken(value))"
    }

    private func extraResetText(_ count: Int) -> String {
        String(format: tr("Extra reset ×%d", "福利重置 ×%d"), count)
    }

    private func periodText(_ cycle: QuotaCycleRecord) -> String {
        "\(Self.periodFormatter.string(from: cycle.startAt)) – \(Self.periodFormatter.string(from: cycle.endAt))"
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
