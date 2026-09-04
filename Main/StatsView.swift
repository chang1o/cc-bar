import SwiftUI
import Charts

// MARK: - StatsRange

enum StatsRange: Hashable, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case thisYear
    case last7
    case last30
    case all
    case custom

    var englishLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Week"
        case .thisMonth: return "Month"
        case .thisYear: return "Year"
        case .last7: return "7d"
        case .last30: return "30d"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    var chineseLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        case .thisYear: return "本年"
        case .last7: return "7 天"
        case .last30: return "30 天"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    private static var weekStartMondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    func bounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date) {
        let cal = Self.weekStartMondayCalendar
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        switch self {
        case .today:
            return (startOfToday, startOfTomorrow)
        case .yesterday:
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (yesterdayStart, startOfToday)
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = cal.date(from: comps) ?? startOfToday
            return (weekStart, startOfTomorrow)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps) ?? startOfToday
            return (monthStart, startOfTomorrow)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let yearStart = cal.date(from: comps) ?? startOfToday
            return (yearStart, startOfTomorrow)
        case .last7:
            let from = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .last30:
            let from = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .all:
            return (.distantPast, .distantFuture)
        case .custom:
            let from = cal.startOfDay(for: customFrom)
            let toBase = cal.startOfDay(for: customTo)
            let to = cal.date(byAdding: .day, value: 1, to: toBase) ?? toBase
            return (from, max(from, to))
        }
    }

    /// Previous range of equal length for deltas; nil for `.all` / `.custom`.
    func previousBounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date)? {
        switch self {
        case .all, .custom:
            return nil
        default:
            break
        }
        let current = bounds(now: now, customFrom: customFrom, customTo: customTo)
        let length = current.to.timeIntervalSince(current.from)
        guard length > 0, length.isFinite else { return nil }
        return (current.from.addingTimeInterval(-length), current.from)
    }
}

enum StatsViewMode: Hashable {
    case overview
    case timeline
    case breakdown
}

enum BreakdownSort: Hashable {
    case day
    case service
    case account
    case model
    case input
    case output
    case cache
    case total
    case cost
}

// MARK: - StatsView

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var range: StatsRange = .today
    /// nil means every visible provider.
    @State private var serviceFilter: Provider?
    @State private var viewMode: StatsViewMode = .overview
    @State private var breakdownSort: BreakdownSort = .day
    @State private var breakdownDescending: Bool = true
    @State private var customFrom: Date = Calendar.current.startOfDay(
        for: Date().addingTimeInterval(-7 * 86400)
    )
    @State private var customTo: Date = Calendar.current.startOfDay(for: Date())

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)

            Divider()

            ScrollView {
                mainContent
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch viewMode {
        case .overview:
            overviewContent
        case .timeline:
            timelineContent
        case .breakdown:
            breakdownContent
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if range == .custom { customRangeRow }

            kpiRow.padding(.top, 6)

            dailyUsagePanel

            HStack(alignment: .top, spacing: 12) {
                byServicePanel
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                currentLimitsPanel
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            }

            byModelPanel
        }
        .padding(20)
    }

    private var breakdownContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if range == .custom { customRangeRow }
            breakdownPanel
        }
        .padding(20)
    }

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineHeader
            if timelineSections.isEmpty {
                placeholderHeight(220, message: tr("No accounts", "暂无账号"))
                    .ccPanel(cornerRadius: 12)
            } else {
                ForEach(timelineSections) { section in
                    QuotaTimelineAccountPanel(section: section)
                }
            }
        }
        .padding(20)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: "Service", chinese: "服务") {
                sidebarItem(english: "All", chinese: "全部", tint: nil, active: serviceFilter == nil) {
                    serviceFilter = nil
                }
                ForEach(appState.visibleProviders, id: \.self) { provider in
                    sidebarItem(
                        english: provider.descriptor.displayName,
                        chinese: provider.descriptor.vendor,
                        tint: provider.accent,
                        active: serviceFilter == provider
                    ) {
                        serviceFilter = provider
                    }
                }
            }

            sidebarGroup(title: "View", chinese: "视图") {
                sidebarItem(
                    english: "Overview",
                    chinese: "概览",
                    icon: "rectangle.split.2x2",
                    active: viewMode == .overview
                ) {
                    viewMode = .overview
                }
                sidebarItem(
                    english: "Timeline",
                    chinese: "时间线",
                    icon: "chart.line.uptrend.xyaxis",
                    active: viewMode == .timeline
                ) {
                    viewMode = .timeline
                }
                sidebarItem(
                    english: "Breakdown",
                    chinese: "明细",
                    icon: "list.bullet",
                    active: viewMode == .breakdown
                ) {
                    viewMode = .breakdown
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear { normalizeServiceFilter() }
        .onChange(of: SettingsStore.shared.enabledProviders) { _, _ in normalizeServiceFilter() }
        .onChange(of: appState.accounts.map(\.id)) { _, _ in normalizeServiceFilter() }
    }

    @ViewBuilder
    private func sidebarGroup<Content: View>(
        title: String,
        chinese: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tr(title, chinese).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            content()
        }
    }

    private func sidebarItem(
        english: String,
        chinese: String,
        tint: Color? = nil,
        icon: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 13, height: 13)
                        .foregroundStyle(active ? Color.white : Color.secondary)
                } else if let tint {
                    ServiceMark(color: tint, size: 8)
                        .frame(width: 13, height: 13, alignment: .center)
                } else {
                    Color.clear.frame(width: 13, height: 13)
                }

                Text(tr(english, chinese))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Picker("", selection: $range) {
                ForEach(StatsRange.allCases, id: \.self) { r in
                    Text(tr(r.englishLabel, r.chineseLabel)).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var customRangeRow: some View {
        HStack(spacing: 12) {
            DatePicker(tr("From", "起"), selection: $customFrom, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker(tr("To", "止"), selection: $customTo, in: customFrom..., displayedComponents: .date)
                .datePickerStyle(.compact)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: 12) {
            KPICard(
                english: "Total tokens",
                chinese: "总 Tokens",
                value: StatsFormatter.compactToken(currentTotalsAll.totalTokens),
                delta: deltaPercent(current: Double(currentTotalsAll.totalTokens),
                                    previous: Double(previousTotalsAll.totalTokens)),
                tint: nil
            )
            if anyCostProvider {
                KPICard(
                    english: "Total spend",
                    chinese: "总花费",
                    value: StatsFormatter.cost(currentTotalsAll.costUSD),
                    delta: deltaPercent(current: currentTotalsAll.costUSD.doubleValue,
                                        previous: previousTotalsAll.costUSD.doubleValue),
                    tint: nil
                )
            }
            ForEach(includedProviders, id: \.self) { provider in
                let current = currentTotals(provider)
                let previous = previousTotals(provider)
                if provider.descriptor.supportsCost {
                    KPICard(
                        english: provider.descriptor.displayName,
                        chinese: provider.descriptor.vendor,
                        value: StatsFormatter.cost(current.costUSD),
                        delta: deltaPercent(current: current.costUSD.doubleValue, previous: previous.costUSD.doubleValue),
                        tint: provider.accent
                    )
                } else {
                    KPICard(
                        english: provider.descriptor.displayName,
                        chinese: provider.descriptor.vendor,
                        value: StatsFormatter.compactToken(current.totalTokens),
                        delta: deltaPercent(current: Double(current.totalTokens), previous: Double(previous.totalTokens)),
                        tint: provider.accent
                    )
                }
            }
        }
    }

    // MARK: Daily usage panel

    private var dailyUsagePanel: some View {
        Panel(title: chartUsesTokens ? "Daily tokens" : "Daily usage",
              chinese: chartUsesTokens ? "每日 Tokens" : "每日用量",
              right: AnyView(
            HStack(spacing: 8) {
                ForEach(includedProviders, id: \.self) { provider in
                    LegendChip(color: provider.accent, label: provider.descriptor.displayName)
                }
            }
        )) {
            VStack(spacing: 6) {
                if dailySamples.isEmpty {
                    placeholderHeight(160, message: tr("No data", "无数据"))
                } else {
                    Chart(dailySamples) { sample in
                        ForEach(includedProviders, id: \.self) { provider in
                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Value", sample.values[provider] ?? 0),
                                stacking: .standard
                            )
                            .foregroundStyle(provider.accent)
                            .cornerRadius(2)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(1, dailySamples.count / 5))) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                           centered: true)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 160)
                }
            }
        }
    }

    // MARK: By service panel

    private var byServicePanel: some View {
        Panel(title: "By service", chinese: "按服务") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(includedProviders, id: \.self) { provider in
                    let totals = currentTotals(provider)
                    ByServiceRow(
                        title: provider.descriptor.displayName,
                        subtitle: provider.descriptor.vendor,
                        tint: provider.accent,
                        valueText: provider.descriptor.supportsCost
                            ? StatsFormatter.cost(totals.costUSD)
                            : StatsFormatter.compactToken(totals.totalTokens),
                        ratio: serviceRatio(provider),
                        ratioLabel: chartUsesTokens ? tr("of tokens", "占比") : tr("of spend", "占比"),
                        tokens: totals.totalTokens
                    )
                }
                if includedProviders.isEmpty {
                    placeholderHeight(96, message: tr("No services enabled", "暂无启用服务"))
                }
            }
        }
    }

    // MARK: Current limits panel

    private var currentLimitsPanel: some View {
        Panel(title: "Current limits", chinese: "当前限额") {
            VStack(spacing: 4) {
                ForEach(includedProviders, id: \.self) { provider in
                    let snapshot = appState.monitorSnapshot(for: provider)
                    let descriptor = provider.descriptor
                    LimitRingRow(
                        label: "\(descriptor.displayName) \((snapshot?.primary?.kind ?? descriptor.primaryKind).shortLabel)",
                        window: snapshot?.primary,
                        tint: provider.accent
                    )
                    if let secondaryKind = descriptor.secondaryKind {
                        LimitRingRow(
                            label: "\(descriptor.displayName) \((snapshot?.secondary?.kind ?? secondaryKind).shortLabel)",
                            window: snapshot?.secondary,
                            tint: provider.accent
                        )
                    }
                }
                if includedProviders.isEmpty {
                    placeholderHeight(96, message: tr("No services enabled", "暂无启用服务"))
                }
            }
        }
    }

    // MARK: By model panel

    private var byModelPanel: some View {
        Panel(title: "By model", chinese: "按模型") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(includedProviders.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider() }
                    modelGroup(provider: provider, rows: modelRows(for: provider))
                }
                if includedProviders.isEmpty {
                    placeholderHeight(96, message: tr("No services enabled", "暂无启用服务"))
                }
            }
        }
    }

    // MARK: Breakdown

    private var breakdownPanel: some View {
        Panel(title: "Breakdown", chinese: "明细") {
            if breakdownRows.isEmpty {
                placeholderHeight(240, message: tr("No data", "无数据"))
            } else {
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        breakdownHeader
                        ForEach(breakdownRows) { row in
                            Divider()
                            breakdownRow(row)
                        }
                    }
                    .frame(minWidth: showsAccountColumn ? 1068 : 948, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    private var showsAccountColumn: Bool {
        Set(filteredBuckets.map(\.accountId)).count > 1
    }

    private var breakdownHeader: some View {
        HStack(spacing: 0) {
            breakdownHeaderCell("Day", "日期", sort: .day, width: 96, alignment: .leading)
            breakdownHeaderCell("Service", "服务", sort: .service, width: 110, alignment: .leading)
            if showsAccountColumn {
                breakdownHeaderCell("Account", "账号", sort: .account, width: 120, alignment: .leading)
            }
            breakdownHeaderCell("Model", "模型", sort: .model, width: 230, alignment: .leading)
            breakdownHeaderCell("Input", "输入", sort: .input, width: 104, alignment: .trailing)
            breakdownHeaderCell("Output", "输出", sort: .output, width: 104, alignment: .trailing)
            breakdownHeaderCell("Cache", "缓存", sort: .cache, width: 104, alignment: .trailing)
            breakdownHeaderCell("Total", "总计", sort: .total, width: 104, alignment: .trailing)
            breakdownHeaderCell("Cost", "花费", sort: .cost, width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func breakdownHeaderCell(
        _ english: String,
        _ chinese: String,
        sort: BreakdownSort,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Button {
            setBreakdownSort(sort)
        } label: {
            HStack(spacing: 4) {
                Text(tr(english, chinese))
                if breakdownSort == sort {
                    Image(systemName: breakdownDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func breakdownRow(_ row: BreakdownRow) -> some View {
        HStack(spacing: 0) {
            breakdownText(StatsFormatter.day(row.day), width: 96, alignment: .leading)
            HStack(spacing: 6) {
                ServiceMark(color: row.provider.accent, size: 7, cornerRadius: 1.8)
                Text(row.provider.descriptor.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            if showsAccountColumn {
                Text(accountLabels[row.accountId] ?? row.accountId)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 120, alignment: .leading)
            }

            Text(row.model)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 230, alignment: .leading)

            breakdownText(StatsFormatter.compactToken(row.totals.inputTokens), width: 104, alignment: .trailing)
            breakdownText(StatsFormatter.compactToken(row.totals.outputTokens), width: 104, alignment: .trailing)
            breakdownText(StatsFormatter.compactToken(row.cacheTokens), width: 104, alignment: .trailing)
            breakdownText(StatsFormatter.compactToken(row.totals.totalTokens), width: 104, alignment: .trailing)
            breakdownText(row.provider.descriptor.supportsCost ? StatsFormatter.cost(row.totals.costUSD) : "—",
                          width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func breakdownText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func setBreakdownSort(_ sort: BreakdownSort) {
        if breakdownSort == sort {
            breakdownDescending.toggle()
        } else {
            breakdownSort = sort
            breakdownDescending = true
        }
    }

    // MARK: Timeline

    private var timelineHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Today 5H Quota", "今日 5H 额度"))
                    .font(.system(size: 18, weight: .semibold))
                Text(tr("Only quota changes are shown.", "仅展示额度发生变化的时间点。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(StatsFormatter.day(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var timelineSections: [QuotaTimelineSection] {
        var sections: [QuotaTimelineSection] = []
        let privacy = SettingsStore.shared.privacyMode
        for provider in includedProviders {
            for (index, account) in appState.accounts(for: provider).enumerated() {
                let key = account.id.raw
                let state = appState.quotaState(for: account)
                let hasAnything = account.credential.canFetchQuota
                    || state.snapshot != nil
                    || appState.quotaHistory.lastSamples[key] != nil
                    || !timelineEvents(for: key).isEmpty
                guard hasAnything else { continue }
                let events = timelineEvents(for: key)
                let sample = appState.quotaHistory.lastSamples[key]
                sections.append(QuotaTimelineSection(
                    accountKey: key,
                    title: "\(provider.descriptor.displayName) · \(account.shortTitle(index: index, privacy: privacy))",
                    tint: provider.accent,
                    currentRemaining: sample?.remainingPercent ?? roundedRemaining(state.snapshot),
                    totalDelta: events.reduce(0) { $0 + $1.deltaPercent },
                    latestEventAt: events.last?.sampledAt,
                    events: events
                ))
            }
        }
        return sections
    }

    private func timelineEvents(for key: String) -> [QuotaChangeEvent] {
        appState.quotaHistory.events
            .filter { $0.accountKey == key }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    private func roundedRemaining(_ snapshot: QuotaSnapshot?) -> Int? {
        guard let remaining = snapshot?.timelineWindow?.remainingPercent else { return nil }
        return max(0, min(100, Int(remaining.rounded())))
    }

    private func modelGroup(provider: Provider, rows: [ModelRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ServiceMark(color: provider.accent, size: 6, cornerRadius: 1.5)
                Text(provider.descriptor.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(.tertiary)
            }
            if rows.isEmpty {
                Text(tr("No data", "无数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.model)
                            .font(.system(size: 12.5))
                        Spacer()
                        Text("\(tr("in", "入")) \(StatsFormatter.compactToken(row.totals.inputWithCacheTokens))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("\(tr("out", "出")) \(StatsFormatter.compactToken(row.totals.outputTokens))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(provider.descriptor.supportsCost
                             ? StatsFormatter.cost(row.totals.costUSD)
                             : StatsFormatter.compactToken(row.totals.totalTokens))
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 96, alignment: .trailing)
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    // MARK: Data helpers

    private var rangeBounds: (from: Date, to: Date) {
        range.bounds(customFrom: customFrom, customTo: customTo)
    }

    private var previousRangeBounds: (from: Date, to: Date)? {
        range.previousBounds(customFrom: customFrom, customTo: customTo)
    }

    private var includedProviders: [Provider] {
        appState.visibleProviders.filter { serviceFilter == nil || serviceFilter == $0 }
    }

    private func includes(_ provider: Provider) -> Bool {
        includedProviders.contains(provider)
    }

    private var anyCostProvider: Bool {
        includedProviders.contains { $0.descriptor.supportsCost }
    }

    /// Charts and ratios fall back to tokens when no included provider has prices.
    private var chartUsesTokens: Bool {
        !anyCostProvider
    }

    private func normalizeServiceFilter() {
        guard let filter = serviceFilter, !appState.visibleProviders.contains(filter) else { return }
        serviceFilter = nil
    }

    private var accountLabels: [String: String] {
        var labels: [String: String] = [:]
        let privacy = SettingsStore.shared.privacyMode
        for provider in Provider.allCases {
            for (index, account) in appState.accounts(for: provider).enumerated() {
                labels[account.id.raw] = account.shortTitle(index: index, privacy: privacy)
            }
        }
        return labels
    }

    private var filteredBuckets: [UsageBucket] {
        let (from, to) = rangeBounds
        let included = Set(includedProviders)
        return appState.usageService.aggregator.snapshot()
            .filter { $0.day >= from && $0.day < to }
            .filter { included.contains($0.provider) }
    }

    private var currentTotalsAll: UsageTotals {
        var t = UsageTotals.zero
        for b in filteredBuckets { t.add(b) }
        return t
    }

    private func currentTotals(_ provider: Provider) -> UsageTotals {
        guard includes(provider) else { return .zero }
        var t = UsageTotals.zero
        for b in filteredBuckets where b.provider == provider { t.add(b) }
        return t
    }

    private var previousTotalsAll: UsageTotals {
        guard let bounds = previousRangeBounds else { return .zero }
        let included = Set(includedProviders)
        var t = UsageTotals.zero
        for b in appState.usageService.aggregator.snapshot()
            where included.contains(b.provider) && b.day >= bounds.from && b.day < bounds.to {
            t.add(b)
        }
        return t
    }

    private func previousTotals(_ provider: Provider) -> UsageTotals {
        guard includes(provider), let bounds = previousRangeBounds else { return .zero }
        var t = UsageTotals.zero
        for b in appState.usageService.aggregator.snapshot()
            where b.provider == provider && b.day >= bounds.from && b.day < bounds.to {
            t.add(b)
        }
        return t
    }

    private func deltaPercent(current: Double, previous: Double) -> Double? {
        guard previousRangeBounds != nil else { return nil }
        guard previous > 0 else { return nil }
        return ((current - previous) / previous) * 100
    }

    private func serviceRatio(_ provider: Provider) -> Double {
        let totals = currentTotals(provider)
        let all = currentTotalsAll
        if chartUsesTokens {
            guard all.totalTokens > 0 else { return 0 }
            return Double(totals.totalTokens) / Double(all.totalTokens)
        }
        let d = all.costUSD.doubleValue
        guard d > 0 else { return 0 }
        return totals.costUSD.doubleValue / d
    }

    private var dailySamples: [DailySample] {
        var byDay: [Date: [Provider: Double]] = [:]
        for b in filteredBuckets {
            var values = byDay[b.day] ?? [:]
            let value = chartUsesTokens ? Double(b.inputTokens + b.outputTokens + b.cacheReadTokens + b.cacheCreationTokens)
                                        : b.costUSD.doubleValue
            values[b.provider, default: 0] += value
            byDay[b.day] = values
        }
        return byDay
            .map { DailySample(day: $0.key, values: $0.value) }
            .sorted { $0.day < $1.day }
    }

    private func modelRows(for provider: Provider) -> [ModelRow] {
        var byModel: [String: UsageTotals] = [:]
        for b in filteredBuckets where b.provider == provider {
            var t = byModel[b.model] ?? .zero
            t.add(b)
            byModel[b.model] = t
        }
        return byModel
            .map { ModelRow(model: $0.key, totals: $0.value) }
            .sorted { lhs, rhs in
                if provider.descriptor.supportsCost { return lhs.totals.costUSD > rhs.totals.costUSD }
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
    }

    private var breakdownRows: [BreakdownRow] {
        let labels = accountLabels
        return filteredBuckets
            .map { bucket in
                var totals = UsageTotals.zero
                totals.add(bucket)
                return BreakdownRow(
                    day: bucket.day,
                    provider: bucket.provider,
                    accountId: bucket.accountId,
                    accountLabel: labels[bucket.accountId] ?? bucket.accountId,
                    model: bucket.model,
                    totals: totals
                )
            }
            .sorted { lhs, rhs in
                let order = breakdownOrder(lhs, rhs)
                guard order != .orderedSame else {
                    return breakdownTieBreak(lhs, rhs)
                }
                return breakdownDescending
                    ? order == .orderedDescending
                    : order == .orderedAscending
            }
    }

    private func breakdownOrder(_ lhs: BreakdownRow, _ rhs: BreakdownRow) -> ComparisonResult {
        switch breakdownSort {
        case .day:
            return compare(lhs.day, rhs.day)
        case .service:
            return lhs.provider.rawValue.localizedStandardCompare(rhs.provider.rawValue)
        case .account:
            return lhs.accountLabel.localizedStandardCompare(rhs.accountLabel)
        case .model:
            return lhs.model.localizedStandardCompare(rhs.model)
        case .input:
            return compare(lhs.totals.inputTokens, rhs.totals.inputTokens)
        case .output:
            return compare(lhs.totals.outputTokens, rhs.totals.outputTokens)
        case .cache:
            return compare(lhs.cacheTokens, rhs.cacheTokens)
        case .total:
            return compare(lhs.totals.totalTokens, rhs.totals.totalTokens)
        case .cost:
            return compare(lhs.totals.costUSD.doubleValue, rhs.totals.costUSD.doubleValue)
        }
    }

    private func breakdownTieBreak(_ lhs: BreakdownRow, _ rhs: BreakdownRow) -> Bool {
        if lhs.day != rhs.day { return lhs.day > rhs.day }
        if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
        if lhs.accountId != rhs.accountId { return lhs.accountId < rhs.accountId }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func placeholderHeight(_ height: CGFloat, message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Panel container

private struct Panel<Content: View>: View {
    let title: String
    let chinese: String
    var right: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tr(title, chinese))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let right { right }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }
}

private struct LegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ServiceMark(color: color, size: 9)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - KPI card

private struct KPICard: View {
    let english: String
    let chinese: String
    let value: String
    let delta: Double?
    let tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let tint {
                    ServiceMark(color: tint, size: 6, cornerRadius: 1.5)
                }
                Text(tr(english, chinese))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .kerning(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                if let delta {
                    Text(formatDelta(delta))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 10)
    }

    private func formatDelta(_ value: Double) -> String {
        let arrow = value >= 0 ? "↑" : "↓"
        let abs = Swift.abs(value)
        return "\(arrow) \(String(format: "%.1f", abs))%"
    }
}

// MARK: - By service row

private struct ByServiceRow: View {
    let title: String
    let subtitle: String
    let tint: Color
    let valueText: String
    let ratio: Double
    let ratioLabel: String
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ServiceMark(color: tint, size: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            ProgressBar(value: ratio, tint: tint, height: 5)
                .padding(.leading, 16)
            HStack {
                Text("\(StatsFormatter.compactToken(tokens)) Tokens")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((ratio * 100).rounded()))% \(ratioLabel)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 16)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Limit ring row

private struct LimitRingRow: View {
    let label: String
    let window: QuotaWindow?
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            ProgressRing(
                value: (window?.remainingPercent ?? 0) / 100,
                tint: ringColor,
                diameter: 32,
                stroke: 4
            ) {
                Text(percentText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(window?.detail ?? formatResetHint(window?.resetsAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private var ringColor: Color {
        guard window != nil else { return .secondary }
        return statusColor(remainingPercent: window?.remainingPercent, tint: tint)
    }

    private var percentText: String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))"
    }
}

// MARK: - Quota timeline

private struct QuotaTimelineAccountPanel: View {
    let section: QuotaTimelineSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if section.events.isEmpty {
                Text(tr("No changes today", "今天暂无变动"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } else {
                QuotaTimelineChart(events: section.events, tint: section.tint)
                    .frame(height: 180)
                QuotaTimelineTable(events: section.events)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 7) {
                ServiceMark(color: section.tint, size: 8)
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            timelineMetric(label: tr("Current", "当前"), value: currentText)
            timelineMetric(label: tr("Today", "今日"), value: StatsFormatter.quotaDelta(section.totalDelta))
            timelineMetric(label: tr("Latest", "最近"), value: latestText)
        }
    }

    private func timelineMetric(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var currentText: String {
        guard let value = section.currentRemaining else { return "--" }
        return "\(value)%"
    }

    private var latestText: String {
        guard let date = section.latestEventAt else { return "--" }
        return StatsFormatter.time(date)
    }
}

private struct QuotaTimelineChart: View {
    let events: [QuotaChangeEvent]
    let tint: Color

    var body: some View {
        Chart(events) { event in
            LineMark(
                x: .value("Time", event.sampledAt),
                y: .value("Remaining", event.afterRemainingPercent)
            )
            .foregroundStyle(tint)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            PointMark(
                x: .value("Time", event.sampledAt),
                y: .value("Remaining", event.afterRemainingPercent)
            )
            .foregroundStyle(statusColor(remainingPercent: Double(event.afterRemainingPercent), tint: tint))
            .symbolSize(34)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct QuotaTimelineTable: View {
    let events: [QuotaChangeEvent]

    private var rows: [QuotaChangeEvent] {
        events.sorted { $0.sampledAt > $1.sampledAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ForEach(rows) { event in
                Divider()
                row(event)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var headerRow: some View {
        HStack {
            tableHeader("Time", "时间", width: 82, alignment: .leading)
            tableHeader("Change", "变动值", width: 82, alignment: .trailing)
            tableHeader("After", "变动后剩余", width: 104, alignment: .trailing)
            tableHeader("Reset", "重置时间", width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func row(_ event: QuotaChangeEvent) -> some View {
        HStack {
            tableText(StatsFormatter.time(event.sampledAt), width: 82, alignment: .leading)
            tableText(StatsFormatter.quotaDelta(event.deltaPercent), width: 82, alignment: .trailing)
                .foregroundStyle(event.deltaPercent < 0 ? Color.red : Color.green)
            tableText("\(event.afterRemainingPercent)%", width: 104, alignment: .trailing)
                .foregroundStyle(statusColor(remainingPercent: Double(event.afterRemainingPercent), tint: .secondary))
            tableText(StatsFormatter.resetTime(event.resetsAt), width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func tableHeader(
        _ english: String,
        _ chinese: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(tr(english, chinese))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Row models

private struct DailySample: Identifiable {
    var id: Date { day }
    let day: Date
    let values: [Provider: Double]
}

private struct ModelRow: Identifiable {
    var id: String { model }
    let model: String
    let totals: UsageTotals
}

private struct BreakdownRow: Identifiable {
    var id: String {
        "\(day.timeIntervalSince1970)-\(accountId)-\(model)"
    }

    let day: Date
    let provider: Provider
    let accountId: String
    let accountLabel: String
    let model: String
    let totals: UsageTotals

    var cacheTokens: Int {
        totals.cacheReadTokens + totals.cacheCreationTokens
    }
}

private struct QuotaTimelineSection: Identifiable {
    var id: String { accountKey }
    let accountKey: String
    let title: String
    let tint: Color
    let currentRemaining: Int?
    let totalDelta: Int
    let latestEventAt: Date?
    let events: [QuotaChangeEvent]
}

// MARK: - Formatter

enum StatsFormatter {
    static func cost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$\(f.string(from: ns) ?? "0.00")"
    }

    static func token(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Compact token count: zh uses 万 / 亿, en uses k / M / B.
    @MainActor
    static func compactToken(_ value: Int) -> String {
        let v = Double(value)
        switch L10n.current {
        case .zh:
            if v >= 100_000_000 {
                return "\(trimTrailingZeros(v / 100_000_000)) 亿"
            }
            if v >= 10_000 {
                return "\(trimTrailingZeros(v / 10_000)) 万"
            }
            return token(value)
        case .en:
            if v >= 1_000_000_000 {
                return String(format: "%.2fB", v / 1_000_000_000)
            }
            if v >= 1_000_000 {
                return String(format: "%.2fM", v / 1_000_000)
            }
            if v >= 1_000 {
                return String(format: "%.1fk", v / 1_000)
            }
            return "\(value)"
        }
    }

    private static func trimTrailingZeros(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        var trimmed = s
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time(date)
    }

    static func quotaDelta(_ value: Int) -> String {
        if value > 0 { return "+\(value)%" }
        return "\(value)%"
    }
}

// MARK: - Decimal helper

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
