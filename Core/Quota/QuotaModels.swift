import Foundation

nonisolated enum QuotaSnapshotSource: String, Sendable, Codable {
    case api
    case cache
    case cliFallback

    var displayName: String {
        switch self {
        case .api: return "API"
        case .cache: return "cache"
        case .cliFallback: return "Claude CLI"
        }
    }
}

nonisolated enum QuotaRefreshReason: Sendable {
    case periodic
    case userInitiated
}

nonisolated struct QuotaRefreshState: Sendable, Equatable {
    var lastSuccessAt: Date?
    var lastAttemptAt: Date?
    var backoffUntil: Date?
    var lastError: String?
    var inFlight: Bool = false
    var source: QuotaSnapshotSource?
}

nonisolated struct QuotaWindow: Sendable, Equatable, Codable {
    var kind: QuotaWindowKind
    /// 0...100, percent already consumed.
    var usedPercent: Double
    var resetsAt: Date?
    var windowSeconds: Int?
    /// Provider-specific detail such as "139/200 requests" or "$7.50 of $60".
    var detail: String?

    init(
        kind: QuotaWindowKind,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowSeconds: Int? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.detail = detail
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

nonisolated struct QuotaSnapshot: Sendable, Equatable, Codable {
    var provider: Provider
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var extra: [QuotaWindow] = []
    var planType: String?
    var fetchedAt: Date

    /// Both lanes plus extras, primary first.
    var allWindows: [QuotaWindow] {
        [primary, secondary].compactMap { $0 } + extra
    }

    func window(_ kind: QuotaWindowKind) -> QuotaWindow? {
        allWindows.first { $0.kind == kind }
    }

    /// The window the "today" quota timeline tracks: the five-hour lane when
    /// the provider has one, otherwise the primary lane.
    var timelineWindow: QuotaWindow? {
        window(.fiveHour) ?? primary
    }

    /// Merge several accounts of one provider into the most constrained view:
    /// each lane keeps the window with the least remaining quota.
    static func mostConstrained(_ snapshots: [QuotaSnapshot]) -> QuotaSnapshot? {
        guard let first = snapshots.first else { return nil }
        func pick(_ windows: [QuotaWindow?]) -> QuotaWindow? {
            windows.compactMap { $0 }.min { $0.remainingPercent < $1.remainingPercent }
        }
        let extraKinds = snapshots.flatMap { $0.extra.map(\.kind) }
        var seen = Set<QuotaWindowKind>()
        let extras = extraKinds.filter { seen.insert($0).inserted }.compactMap { kind in
            pick(snapshots.map { $0.extra.first { $0.kind == kind } })
        }
        return QuotaSnapshot(
            provider: first.provider,
            primary: pick(snapshots.map(\.primary)),
            secondary: pick(snapshots.map(\.secondary)),
            extra: extras,
            planType: nil,
            fetchedAt: snapshots.map(\.fetchedAt).max() ?? first.fetchedAt
        )
    }
}

nonisolated enum QuotaError: Error, CustomStringConvertible {
    case missingToken
    case missingCookie
    case http(Int, String)
    case transport(String)
    case decode(String)
    case tokenRefreshFailed(String)
    /// The OAuth server rejected the refresh token (typically `invalid_grant`):
    /// another client rotated it first, or the user signed out. Only a new login helps.
    case tokenRevoked

    var description: String {
        switch self {
        case .missingToken: return "missing access token"
        case .missingCookie: return "missing cookie; paste one in Settings"
        case .http(let code, let msg): return "http \(code): \(msg)"
        case .transport(let msg): return "transport: \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .tokenRefreshFailed(let msg): return "token refresh failed: \(msg)"
        case .tokenRevoked:
            return "Claude login expired; run `claude` in a terminal to sign in again"
        }
    }

    var httpStatusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isRateLimited: Bool {
        httpStatusCode == 429
    }

    var isAuthFailure: Bool {
        httpStatusCode == 401 || httpStatusCode == 403
    }

    var isAuthRevoked: Bool {
        if case .tokenRevoked = self { return true }
        return false
    }
}

/// Shared JSON helpers for provider clients whose numeric fields arrive as
/// either numbers or strings.
nonisolated enum QuotaJSON {
    nonisolated static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return d.isFinite ? Int(d) : nil
        case let s as String:
            if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return n }
            if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return Int(d) }
            return nil
        default: return nil
        }
    }

    nonisolated static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d.isFinite ? d : nil
        case let n as Int: return Double(n)
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    nonisolated static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    nonisolated static func epochMillis(_ value: Any?) -> Date? {
        guard let n = double(value), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}
