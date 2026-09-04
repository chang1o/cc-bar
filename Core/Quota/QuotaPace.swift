import Foundation

/// Compares consumed quota against elapsed window time. A positive delta means usage
/// runs ahead of an even burn rate and will exhaust the window before it resets.
nonisolated struct QuotaPace: Sendable, Equatable {
    /// `usedPercent - elapsedPercent`.
    let deltaPercent: Double
    /// Projected exhaustion time; nil when the window lasts until its reset.
    let runsOutAt: Date?

    var isAhead: Bool { deltaPercent > 0 }

    /// Windows with less than this share elapsed have no meaningful pace yet.
    nonisolated static let minimumElapsedFraction = 0.03

    nonisolated static func compute(limit: QuotaLimit, now: Date = Date()) -> QuotaPace? {
        let window = limit.window
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        guard let seconds = windowSeconds(for: limit, resetsAt: resetsAt), seconds > 0 else { return nil }
        let remainingSeconds = resetsAt.timeIntervalSince(now)
        let elapsed = max(0, min(1, 1 - remainingSeconds / Double(seconds)))
        guard elapsed >= minimumElapsedFraction else { return nil }

        let used = max(0, min(1, window.usedPercent / 100))
        let delta = ((used - elapsed) * 100).rounded()

        var runsOutAt: Date?
        if used >= 1 {
            runsOutAt = now
        } else if used > elapsed, used > 0 {
            let rate = used / (elapsed * Double(seconds)) // fraction per second
            let projected = now.addingTimeInterval((1 - used) / rate)
            if projected < resetsAt { runsOutAt = projected }
        }
        return QuotaPace(deltaPercent: delta, runsOutAt: runsOutAt)
    }

    /// Explicit length, then the kind default, then a calendar month ending at the reset
    /// (monthly lanes such as Ollama "Monthly usage" or Claude extra usage).
    nonisolated static func windowSeconds(for limit: QuotaLimit, resetsAt: Date) -> Int? {
        if let seconds = limit.defaultWindowSeconds { return seconds }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        let seconds = resetsAt.timeIntervalSince(start)
        return seconds > 0 ? Int(seconds.rounded()) : nil
    }
}
