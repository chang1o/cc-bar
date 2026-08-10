import SwiftUI

private enum CycleWindowChoice: String, CaseIterable, Identifiable {
    case weekly
    case fiveHour

    var id: String { rawValue }

    var limitKind: QuotaLimitKind {
        switch self {
        case .weekly: return .weekly
        case .fiveHour: return .fiveHour
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .weekly: return tr("Weekly", "周周期")
        case .fiveHour: return tr("5-hour", "5 小时")
        }
    }
}

struct CycleStatsView: View {
    @Environment(AppState.self) private var appState
    let serviceFilter: StatsServiceFilter

    @State private var windowChoice: CycleWindowChoice = .weekly
    @State private var visibleCount = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if appState.usageService.isCycleRebuilding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Rebuilding cycle history…", "正在补算周期历史…"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            currentSection
            historySection
        }
        .padding(20)
        .onChange(of: windowChoice) { _, _ in visibleCount = 50 }
        .onChange(of: serviceFilter) { _, _ in visibleCount = 50 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Official reset cycles", "官方重置周期"))
                    .font(.system(size: 18, weight: .semibold))
                Text(tr(
                    "Local Tokens and API-equivalent cost grouped by each provider's real reset window.",
                    "按各服务真实重置窗口汇总本机 Token 与 API 等值费用。"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $windowChoice) {
                ForEach(CycleWindowChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        let rows = currentSummaries
        if rows.isEmpty {
            cycleEmptyState(
                title: tr("Waiting for the current cycle", "等待当前周期"),
                detail: tr("A successful quota refresh will establish the reset boundary.", "额度刷新成功后会建立真实重置边界。")
            )
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(2, rows.count)),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(rows) { summary in
                    currentCard(summary)
                }
            }
        }
    }

    private func currentCard(_ summary: CycleUsageSummary) -> some View {
        let used = max(0, min(100, summary.cycle.latestUsedPercent))
        let remaining = 100 - used
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                ServiceMark(color: summary.cycle.app.tintColor)
                Text(summary.cycle.app.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(tr("In progress", "进行中"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if summary.cycle.extraResetCount > 0 {
                    Text(extraResetText(summary.cycle.extraResetCount))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.09), in: Capsule())
                }
                Spacer()
                ResetTimeText(resetsAt: summary.cycle.endAt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ProgressView(value: remaining, total: 100)
                    .progressViewStyle(.linear)
                    .tint(statusColor(remainingPercent: remaining, tint: summary.cycle.app.tintColor))
                HStack {
                    Text(tr("Remaining / Used", "剩余 / 已用"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%% / %.1f%%", remaining, used))
                        .fontWeight(.semibold)
                }
                .font(.system(size: 11))
                .monospacedDigit()
            }

            HStack(spacing: 0) {
                currentMetric(
                    tr("Actual Tokens", "实际 Tokens"),
                    StatsFormatter.compactToken(summary.totals.totalTokens)
                )
                currentMetric(
                    tr("Actual API cost", "实际 API 等值费用"),
                    StatsFormatter.tierCostPrecise(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage)
                )
                currentMetric(
                    tr("Projected Tokens", "预计完整 Tokens"),
                    forecastTokenText(summary.projectedFullCycleTokens)
                )
                currentMetric(
                    tr("Projected API cost", "预计完整 API 费用"),
                    forecastCostText(summary.projectedFullCycleCostUSD)
                )
            }

            if let confidence = summary.forecastConfidence {
                HStack(spacing: 6) {
                    forecastConfidenceBadge(confidence)
                    Text(String(format: tr(
                        "Forecast uses %.1f%% observed use in the current allowance.",
                        "预估基于当前额度段已观察的 %.1f%% 用量。"
                    ), summary.forecastObservedPercent))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .ccPanel(cornerRadius: 12)
    }

    private func currentMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Cycle history", "周期历史"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(tr("Completed cycles only", "仅展示已结束周期"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(tr("Forecast starts after 10% observed use", "观察用量达到 10% 后开始预估"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if completedSummaries.isEmpty {
                Text(tr("No completed cycles yet", "暂无已结束周期"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                cycleTable
                if completedSummaries.count > visibleCount {
                    Button(tr("Load 50 more", "再加载 50 条")) {
                        visibleCount += 50
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()
            Text(tr(
                "Actual usage only includes local logs found by CCBar. Forecasts scale the current allowance's Tokens and API-equivalent cost by its observed quota change; prior allowance usage is kept when an extra reset is detected. Results are not official limits.",
                "实际用量只包含 CCBar 能读取到的本机日志。预估按当前额度段的 Token、API 等值费用与额度变化比例推算；检测到福利重置时会保留此前实际用量。结果不代表官方额度。"
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .ccPanel(cornerRadius: 12)
    }

    private var cycleTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                tableHeader(tr("Period", "周期"), width: 174)
                tableHeader(tr("Actual Tokens", "实际 Tokens"), width: 80, alignment: .trailing)
                tableHeader(tr("Actual cost", "实际费用"), width: 82, alignment: .trailing)
                tableHeader(tr("Observed use", "观察用量"), width: 76, alignment: .trailing)
                tableHeader(tr("Projected Tokens", "预计 Tokens"), width: 98, alignment: .trailing)
                tableHeader(tr("Projected cost", "预计费用"), width: 92, alignment: .trailing)
                tableHeader(tr("Resets", "重置"), width: 62, alignment: .center)
                tableHeader(tr("Forecast", "预估"), width: 66, alignment: .center)
                tableHeader(tr("Quality", "质量"), width: 64, alignment: .center)
            }
            .padding(.bottom, 7)

            Divider().gridCellColumns(9)

            ForEach(Array(completedSummaries.prefix(visibleCount).enumerated()), id: \.element.id) { index, summary in
                cycleTableRow(summary)
                    .padding(.vertical, 8)
                if index < min(visibleCount, completedSummaries.count) - 1 {
                    Divider().gridCellColumns(9)
                }
            }
        }
    }

    private func cycleTableRow(_ summary: CycleUsageSummary) -> some View {
        GridRow {
            HStack(spacing: 7) {
                ServiceMark(color: summary.cycle.app.tintColor, size: 7, cornerRadius: 1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(periodText(summary.cycle))
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(summary.cycle.app.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 174, alignment: .leading)

            tableValue(StatsFormatter.compactToken(summary.totals.totalTokens), width: 80)
            tableValue(
                StatsFormatter.tierCostPrecise(summary.totals.costUSD, hasUnpricedUsage: summary.totals.hasUnpricedUsage),
                width: 82
            )
            tableValue(observedUseText(summary.cycle), width: 76)
            tableValue(forecastTokenText(summary.projectedFullCycleTokens), width: 98)
            tableValue(forecastCostText(summary.projectedFullCycleCostUSD), width: 92)
            Text(summary.cycle.extraResetCount == 0 ? "—" : "×\(summary.cycle.extraResetCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(summary.cycle.extraResetCount == 0 ? .tertiary : .secondary)
                .frame(width: 62, alignment: .center)
            forecastConfidenceBadge(summary.forecastConfidence)
                .frame(width: 66, alignment: .center)
            qualityBadge(summary.quality)
                .frame(width: 64, alignment: .center)
        }
    }

    private func tableHeader(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func tableValue(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func qualityBadge(_ quality: CycleUsageQuality) -> some View {
        let title: String
        switch quality {
        case .exact: title = tr("Exact", "精确")
        case .estimated: title = tr("Estimated", "估算")
        case .incomplete: title = tr("Partial", "不完整")
        }
        return Text(title)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    private func forecastConfidenceBadge(_ confidence: CycleForecastConfidence?) -> some View {
        let title: String
        switch confidence {
        case .rough: title = tr("Rough", "粗略")
        case .reference: title = tr("Reference", "参考")
        case .reliable: title = tr("Reliable", "较可靠")
        case nil: title = "—"
        }
        return Text(title)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(confidence == nil ? .tertiary : .secondary)
            .padding(.horizontal, confidence == nil ? 0 : 7)
            .padding(.vertical, confidence == nil ? 0 : 3)
            .background(
                confidence == nil ? Color.clear : Color.secondary.opacity(0.09),
                in: Capsule()
            )
    }

    private func cycleEmptyState(title: String, detail: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .ccPanel(cornerRadius: 12)
    }

    private var accountKeys: [UsageApp: String] {
        var result: [UsageApp: String] = [:]
        if appState.codexAccount != nil {
            result[.codex] = QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId)
        }
        if appState.claudeAccount != nil {
            result[.claude] = QuotaHistoryAccountKey.claudePrimary()
        }
        return result
    }

    private var selectedApp: UsageApp? {
        switch serviceFilter {
        case .codex: return .codex
        case .claude: return .claude
        case .all, .pi, .opencode: return nil
        }
    }

    private var summaries: [CycleUsageSummary] {
        appState.usageService.cycleAggregator.summaries(
            cycles: appState.quotaCycles.records,
            kind: windowChoice.limitKind,
            app: selectedApp
        )
    }

    private var currentSummaries: [CycleUsageSummary] {
        summaries.filter {
            $0.cycle.isCurrent()
                && accountKeys[$0.cycle.app] == $0.cycle.accountKey
        }
    }

    private var completedSummaries: [CycleUsageSummary] {
        summaries.filter { $0.cycle.isComplete() && $0.hasLocalUsage }
    }

    private func forecastCostText(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return StatsFormatter.tierCostPrecise(value, hasUnpricedUsage: false)
    }

    private func forecastTokenText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return StatsFormatter.compactToken(value)
    }

    private func observedUseText(_ cycle: QuotaCycleRecord) -> String {
        guard cycle.firstSampleAt != nil else { return "—" }
        return String(format: "%.1f%%", cycle.totalObservedUsedPercent)
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
