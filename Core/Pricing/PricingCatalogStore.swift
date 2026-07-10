import Foundation
import os

/// LiteLLM / models.dev 远端价格目录：内存快照 + 磁盘缓存 + 后台刷新（stale-while-revalidate）。
///
/// 用锁保护的普通 class（不用 `actor`）：`rate(for:)` 必须保持同步调用，因为它被 `Pricing.cost()`
/// 同步调用，而 `Pricing.cost()` 又被两个 JSONL Scanner 同步调用——接远端价格目录不应该把整条
/// 计价链路改成 async。刷新（网络 I/O）本身仍然是 `Task.detached` 里的 async 工作，只是读侧保持同步。
nonisolated final class PricingCatalogStore: @unchecked Sendable {
    static let shared = PricingCatalogStore()

    /// `active` 是当前扫描可读取的冻结价格快照；后台刷新只更新 `pending`，由下一次
    /// 扫描开始时统一提交，避免同一批 JSONL 前后读到不同价格。
    private struct CatalogState {
        var active: PricingCatalogCachePayload
        var pending: PricingCatalogCachePayload?
    }

    private enum Source: Sendable {
        case liteLLM
        case modelsDev

        func state(in payload: PricingCatalogCachePayload) -> PricingSourceState {
            switch self {
            case .liteLLM: payload.liteLLM
            case .modelsDev: payload.modelsDev
            }
        }

        func update(
            _ payload: inout PricingCatalogCachePayload,
            _ body: (inout PricingSourceState) -> Void
        ) {
            switch self {
            case .liteLLM: body(&payload.liteLLM)
            case .modelsDev: body(&payload.modelsDev)
            }
        }
    }

    private let refreshInterval: TimeInterval = 24 * 3600
    private let failureRetryInterval: TimeInterval = 30 * 60
    private let suspiciousShrinkMinimumExistingCount = 20

    private let state: OSAllocatedUnfairLock<CatalogState>
    private let refreshRunning = OSAllocatedUnfairLock(initialState: false)

    private static let liteLLMURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!
    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    private init() {
        state = OSAllocatedUnfairLock(initialState: CatalogState(active: PricingCatalogCache.load()))
    }

    /// 快速同步读取，零 I/O，不阻塞调用方。LiteLLM 优先于 models.dev。
    func rate(for normalizedKey: String) -> ModelPrice? {
        state.withLock { catalog in
            catalog.active.liteLLM.rates[normalizedKey] ?? catalog.active.modelsDev.rates[normalizedKey]
        }
    }

    /// 扫描开始前提交已完成刷新的目录。扫描进行中产生的新目录继续留在 pending，
    /// 留给下一次扫描使用，保证 `Pricing.cost()` 和最终 fingerprint 读取同一份价格表。
    func commitPending() {
        state.withLock { catalog in
            guard let pending = catalog.pending else { return }
            catalog.active = pending
            catalog.pending = nil
        }
    }

    /// App 启动、以及每次用量扫描开始时调用。非阻塞：内部判断是否到期，真正到期才会
    /// 发起网络请求；已有刷新在跑则直接返回，不重复起任务。
    func refreshIfNeeded() {
        let now = Date()
        let due = state.withLock { catalog in
            let payload = catalog.pending ?? catalog.active
            return isDue(payload.liteLLM, now: now) || isDue(payload.modelsDev, now: now)
        }
        guard due else { return }

        let alreadyRunning = refreshRunning.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.refreshRunning.withLock { $0 = false }
        }
    }

    private func isDue(_ source: PricingSourceState, now: Date) -> Bool {
        if let failedAt = source.failedAt, now.timeIntervalSince(failedAt) < failureRetryInterval {
            return false
        }
        guard let fetchedAt = source.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= refreshInterval
    }

    private func performRefresh() async {
        await refreshSource(url: Self.liteLLMURL, source: .liteLLM, decode: LiteLLMPricingDecoder.decode)
        await refreshSource(url: Self.modelsDevURL, source: .modelsDev, decode: ModelsDevPricingDecoder.decode)
    }

    private func refreshSource(
        url: URL,
        source: Source,
        decode: @Sendable (Data) throws -> [String: ModelPrice]
    ) async {
        let now = Date()
        let (due, previousSource) = state.withLock { catalog -> (Bool, PricingSourceState) in
            let payload = catalog.pending ?? catalog.active
            let sourceState = source.state(in: payload)
            return (isDue(sourceState, now: now), sourceState)
        }
        guard due else { return }

        switch await PricingCatalogClient.fetch(url: url, etag: previousSource.etag) {
        case .success(.notModified):
            mutatePending { payload in
                source.update(&payload) {
                    $0.fetchedAt = now
                    $0.failedAt = nil
                }
            }
            persist()

        case .success(.updated(let data, let newEtag)):
            do {
                // 解码即校验；结果为空也会被 decode 抛出（emptyFeed），一并走 catch。
                let rates = try decode(data)
                guard !isSuspiciousShrink(rates, comparedTo: previousSource.rates) else {
                    // 可疑的部分目录不能覆盖旧数据。清掉 ETag，确保退避后是一次完整拉取，
                    // 而不是对这份可疑内容收到 304 后把旧 rates 误标为新鲜。
                    mutatePending { payload in
                        source.update(&payload) {
                            $0.etag = nil
                            $0.failedAt = now
                        }
                    }
                    persist()
                    print("[PricingCatalog 价格目录] 条目异常缩水，保留旧缓存 suspicious shrink, kept old cache: \(url.lastPathComponent) old=\(previousSource.rates.count) new=\(rates.count)")
                    return
                }
                mutatePending { payload in
                    source.update(&payload) {
                        $0.rates = rates
                        $0.etag = newEtag
                        $0.fetchedAt = now
                        $0.failedAt = nil
                    }
                }
                persist()
            } catch {
                // 远端请求成功不等于价格正确：解析失败/结果为空一律保留旧缓存，只记退避时间戳。
                mutatePending { payload in
                    source.update(&payload) {
                        $0.etag = nil
                        $0.failedAt = now
                    }
                }
                persist()
                print("[PricingCatalog 价格目录] 解析失败，保留旧缓存 decode failed, kept old cache: \(url.lastPathComponent) \(error)")
            }

        case .failure(let err):
            mutatePending { payload in
                source.update(&payload) { $0.failedAt = now }
            }
            persist()
            print("[PricingCatalog 价格目录] 拉取失败，保留旧缓存 fetch failed, kept old cache: \(url.lastPathComponent) \(err)")
        }
    }

    private func mutatePending(_ update: (inout PricingCatalogCachePayload) -> Void) {
        state.withLock { catalog in
            var payload = catalog.pending ?? catalog.active
            update(&payload)
            catalog.pending = payload
        }
    }

    private func isSuspiciousShrink(_ newRates: [String: ModelPrice], comparedTo oldRates: [String: ModelPrice]) -> Bool {
        oldRates.count >= suspiciousShrinkMinimumExistingCount && newRates.count * 2 < oldRates.count
    }

    private func persist() {
        // pending 是最近一次成功或失败刷新后的最新磁盘态；下次 App 启动可直接把它作为 active。
        let snapshot = state.withLock { $0.pending ?? $0.active }
        do {
            try PricingCatalogCache.save(snapshot)
        } catch {
            print("[PricingCatalog 价格目录] 写盘失败 save failed: \(error)")
        }
    }
}

/// 远端价格 JSON 的网络请求封装，风格对齐 `Core/Quota/CodexQuotaClient.swift`。
enum PricingCatalogClient {
    enum FetchOutcome: Sendable {
        case notModified
        case updated(Data, etag: String?)
    }

    enum FetchError: Error, Sendable {
        case transport(String)
        case http(Int)
    }

    nonisolated static func fetch(url: URL, etag: String?) async -> Result<FetchOutcome, FetchError> {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = resp as? HTTPURLResponse else { return .failure(.transport("non-http")) }

        switch http.statusCode {
        case 304:
            return .success(.notModified)
        case 200..<300:
            return .success(.updated(data, etag: http.value(forHTTPHeaderField: "Etag")))
        default:
            return .failure(.http(http.statusCode))
        }
    }
}

/// `pricing-catalog.json` 磁盘缓存，风格对齐 `Core/Storage/QuotaCache.swift`。
enum PricingCatalogCache {
    nonisolated private static let fileName = "pricing-catalog.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> PricingCatalogCachePayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(PricingCatalogCachePayload.self, from: data),
              payload.version == PricingCatalogCachePayload.currentVersion
        else {
            return PricingCatalogCachePayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: PricingCatalogCachePayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
