import Foundation

/// Cursor Dashboard 远端用量拉取错误。错误文本不含 Cookie、token 或响应体。
nonisolated enum CursorUsageError: Error, Sendable, CustomStringConvertible, Equatable {
    case missingCookie
    case invalidRange
    case transport(String)
    case http(Int)
    case invalidPage(String)
    case paginationInconsistent(expected: Int, received: Int)
    case paginationIncomplete(expected: Int, received: Int)
    case pageLimitReached
    case singleDayTooDense
    case invalidTimestamp
    case numericOverflow

    var httpStatusCode: Int? {
        if case .http(let status) = self { return status }
        return nil
    }

    var isRateLimited: Bool { httpStatusCode == 429 }

    var description: String {
        switch self {
        case .missingCookie: return "Cursor credential is unavailable"
        case .invalidRange: return "Cursor usage date range is invalid"
        case .transport(let message): return "Cursor usage request failed: \(message)"
        case .http(let status): return "Cursor usage request failed (HTTP \(status))"
        case .invalidPage(let message): return "Cursor usage response is invalid: \(message)"
        case .paginationInconsistent: return "Cursor usage pagination changed during refresh"
        case .paginationIncomplete: return "Cursor usage pagination is incomplete"
        case .pageLimitReached: return "Cursor usage page limit reached"
        case .singleDayTooDense: return "Cursor usage exceeds the single-day page limit"
        case .invalidTimestamp: return "Cursor usage response contains an invalid timestamp"
        case .numericOverflow: return "Cursor usage response exceeds supported numeric range"
        }
    }
}

nonisolated struct CursorUsageFetchResult: Sendable, Equatable {
    var buckets: [UsageBucket]
    /// 已完整拉取并可按自然日原子替换的范围，右端为开区间。
    var dayRange: Range<Date>
}

/// Cursor Dashboard `get-filtered-usage-events` 的兼容层。
///
/// 没有稳定事件 ID，因此分页只有在服务端总数一致、短页/空页确认结束、且边界重叠
/// 可按总数精确消解时才会发布。任何失败都由调用方保留上一次远端快照。
nonisolated enum CursorUsageFetcher {
    static let endpoint = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    static let pageSize = 1_000
    static let maxPages = 200

    static func fetch(
        cookieHeader: String,
        from: Date,
        to: Date,
        calendar: Calendar = .current
    ) async -> Result<CursorUsageFetchResult, CursorUsageError> {
        let cookie = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return .failure(.missingCookie) }
        guard from < to else { return .failure(.invalidRange) }

        do {
            let events = try await fetchCompleteEvents(
                cookieHeader: cookie,
                from: from,
                to: to,
                calendar: calendar
            )
            let buckets = try makeBuckets(events: events, calendar: calendar)
            let dayRange = try replacementDayRange(from: from, to: to, calendar: calendar)
            return .success(CursorUsageFetchResult(buckets: buckets, dayRange: dayRange))
        } catch let error as CursorUsageError {
            return .failure(error)
        } catch {
            return .failure(.transport(String(describing: error)))
        }
    }

    /// 用于离线夹具测试：和网络路径共享同一映射规则。
    static func parsePage(data: Data) throws -> CursorUsagePage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorUsageError.invalidPage("root is not an object")
        }
        return try parsePage(root: root)
    }

    /// 用于离线夹具测试：缺失/负数/无效 `chargedCents` 会保留 token 与请求数，
    /// 同时标记对应日桶 `costIncomplete` 供诊断，已知费用仍可展示，不会混入本地缺价语义。
    static func makeBuckets(
        events: [CursorUsageEvent],
        calendar: Calendar = .current
    ) throws -> [UsageBucket] {
        var buckets: [BucketKey: UsageBucket] = [:]
        for event in events {
            guard let timestampMS = event.timestampMS, timestampMS > 0 else {
                throw CursorUsageError.invalidTimestamp
            }
            let timestamp = Date(timeIntervalSince1970: Double(timestampMS) / 1_000)
            let day = calendar.startOfDay(for: timestamp)
            let model = event.model ?? "unknown"
            let key = BucketKey(day: day, model: model)
            var bucket = buckets[key] ?? UsageBucket(
                app: .cursor,
                model: model,
                speed: .standard,
                day: day,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0,
                requestCount: 0,
                hasUnpricedUsage: false,
                costIncomplete: false
            )

            bucket.inputTokens = try checkedAdd(bucket.inputTokens, event.inputTokens)
            bucket.outputTokens = try checkedAdd(bucket.outputTokens, event.outputTokens)
            bucket.cacheReadTokens = try checkedAdd(bucket.cacheReadTokens, event.cacheReadTokens)
            bucket.cacheCreationTokens = try checkedAdd(bucket.cacheCreationTokens, event.cacheWriteTokens)
            bucket.requestCount = try checkedAdd(bucket.requestCount, 1)
            switch event.chargedCents {
            case .valid(let cents):
                bucket.costUSD += cents / 100
            case .missingOrInvalid:
                bucket.costIncomplete = true
            }
            buckets[key] = bucket
        }
        return Array(buckets.values)
    }

    private static func fetchCompleteEvents(
        cookieHeader: String,
        from: Date,
        to: Date,
        calendar: Calendar
    ) async throws -> [CursorUsageEvent] {
        do {
            return try await fetchWindow(cookieHeader: cookieHeader, from: from, to: to)
        } catch CursorUsageError.pageLimitReached {
            let startDay = calendar.startOfDay(for: from)
            let endDay = calendar.startOfDay(for: to)
            let dayCount = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
            guard dayCount > 1,
                  let midpoint = calendar.date(byAdding: .day, value: dayCount / 2, to: startDay),
                  midpoint > from, midpoint < to
            else {
                throw CursorUsageError.singleDayTooDense
            }
            async let left = fetchCompleteEvents(
                cookieHeader: cookieHeader,
                from: from,
                to: midpoint,
                calendar: calendar
            )
            async let right = fetchCompleteEvents(
                cookieHeader: cookieHeader,
                from: midpoint,
                to: to,
                calendar: calendar
            )
            let (leftEvents, rightEvents) = try await (left, right)
            return leftEvents + rightEvents
        }
    }

    private static func fetchWindow(
        cookieHeader: String,
        from: Date,
        to: Date
    ) async throws -> [CursorUsageEvent] {
        var pages: [[CursorUsageEvent]] = []
        var expectedTotal: Int?
        var completed = false

        for pageNumber in 1...maxPages {
            let page = try await fetchPage(
                cookieHeader: cookieHeader,
                page: pageNumber,
                from: from,
                to: to
            )
            guard let total = page.totalUsageEventsCount else {
                throw CursorUsageError.invalidPage("missing totalUsageEventsCount")
            }
            if let expectedTotal, expectedTotal != total {
                throw CursorUsageError.paginationInconsistent(expected: expectedTotal, received: total)
            }
            expectedTotal = total

            if page.events.isEmpty {
                completed = true
                break
            }
            pages.append(page.events)
            if page.events.count < pageSize {
                completed = true
                break
            }
        }

        let rawEvents = pages.flatMap(\.self)
        guard completed else { throw CursorUsageError.pageLimitReached }
        guard let expectedTotal else {
            throw CursorUsageError.invalidPage("missing totalUsageEventsCount")
        }
        guard rawEvents.count >= expectedTotal else {
            throw CursorUsageError.paginationIncomplete(expected: expectedTotal, received: rawEvents.count)
        }
        guard rawEvents.count > expectedTotal else { return rawEvents }

        var removalsRemaining = rawEvents.count - expectedTotal
        var reconciled = pages.first ?? []
        for index in pages.indices.dropFirst() {
            let page = pages[index]
            let overlap = boundaryOverlap(previousPage: pages[index - 1], currentPage: page)
            let removalCount = min(overlap, removalsRemaining)
            reconciled.append(contentsOf: page.dropFirst(removalCount))
            removalsRemaining -= removalCount
        }
        guard removalsRemaining == 0, reconciled.count == expectedTotal else {
            throw CursorUsageError.paginationInconsistent(expected: expectedTotal, received: rawEvents.count)
        }
        return reconciled
    }

    private static func fetchPage(
        cookieHeader: String,
        page: Int,
        from: Date,
        to: Date
    ) async throws -> CursorUsagePage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "page": page,
            "pageSize": pageSize,
            "startDate": millisecondsString(from),
            "endDate": millisecondsString(to),
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CursorUsageError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageError.transport("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CursorUsageError.http(http.statusCode)
        }
        return try parsePage(data: data)
    }

    private static func parsePage(root: [String: Any]) throws -> CursorUsagePage {
        guard let rawEvents = root["usageEventsDisplay"] as? [[String: Any]] else {
            throw CursorUsageError.invalidPage("missing usageEventsDisplay")
        }
        let total = nonNegativeInt(root["totalUsageEventsCount"])
        if root["totalUsageEventsCount"] != nil, total == nil {
            throw CursorUsageError.invalidPage("invalid totalUsageEventsCount")
        }
        return CursorUsagePage(
            totalUsageEventsCount: total,
            events: rawEvents.map(CursorUsageEvent.init)
        )
    }

    private static func replacementDayRange(
        from: Date,
        to: Date,
        calendar: Calendar
    ) throws -> Range<Date> {
        let startDay = calendar.startOfDay(for: from)
        guard let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)),
              startDay < endDay
        else {
            throw CursorUsageError.invalidRange
        }
        return startDay..<endDay
    }

    private static func boundaryOverlap(
        previousPage: [CursorUsageEvent],
        currentPage: [CursorUsageEvent]
    ) -> Int {
        let limit = min(previousPage.count, currentPage.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1)
            where previousPage.suffix(count).elementsEqual(currentPage.prefix(count))
        {
            return count
        }
        return 0
    }

    private static func millisecondsString(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CursorUsageError.numericOverflow }
        return sum
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let value = int64(value), value >= 0 else { return nil }
        return Int(exactly: value)
    }

    /// JSONSerialization 把 JSON 的 true / false 解析成 CFBoolean，但值为 0 或 1 的
    /// 普通数字同样满足 `is Bool` 桥接判定。必须按 CFTypeID 精确区分，否则
    /// totalUsageEventsCount 取 0 或 1 时会被误判成布尔、整页解析直接失败，
    /// chargedCents 取 0 或 1 时则会把该日桶错标成费用不完整。
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func int64(_ value: Any?) -> Int64? {
        if isBoolean(value) { return nil }
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber:
            let number = value.doubleValue
            return number.isFinite ? Int64(exactly: number) : nil
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func nonNegativeTokenCount(_ value: Any?) -> Int {
        guard let value = int64(value), value >= 0, let int = Int(exactly: value) else { return 0 }
        return int
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if isBoolean(value) { return nil }
        let raw: String
        switch value {
        case let value as String:
            raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let value as NSNumber:
            raw = value.stringValue
        default:
            return nil
        }
        guard let parsed = Decimal(plainString: raw), parsed >= 0 else { return nil }
        return parsed
    }

    private struct BucketKey: Hashable {
        var day: Date
        var model: String
    }

    fileprivate enum ChargedCents: Equatable {
        case valid(Decimal)
        case missingOrInvalid
    }

    struct CursorUsagePage: Equatable, Sendable {
        var totalUsageEventsCount: Int?
        var events: [CursorUsageEvent]
    }

    struct CursorUsageEvent: Equatable, Sendable {
        var timestampMS: Int64?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
        var cacheWriteTokens: Int
        var cacheReadTokens: Int
        fileprivate var chargedCents: ChargedCents

        init(_ root: [String: Any]) {
            timestampMS = CursorUsageFetcher.int64(root["timestamp"])
            model = (root["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if model?.isEmpty == true { model = nil }
            let tokenUsage = root["tokenUsage"] as? [String: Any] ?? [:]
            inputTokens = CursorUsageFetcher.nonNegativeTokenCount(tokenUsage["inputTokens"])
            outputTokens = CursorUsageFetcher.nonNegativeTokenCount(tokenUsage["outputTokens"])
            cacheWriteTokens = CursorUsageFetcher.nonNegativeTokenCount(tokenUsage["cacheWriteTokens"])
            cacheReadTokens = CursorUsageFetcher.nonNegativeTokenCount(tokenUsage["cacheReadTokens"])
            if let cents = CursorUsageFetcher.decimal(root["chargedCents"]) {
                chargedCents = .valid(cents)
            } else {
                chargedCents = .missingOrInvalid
            }
        }
    }
}
