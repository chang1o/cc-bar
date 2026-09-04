import Foundation

/// Compares consumed quota against elapsed window time. A positive delta means
/// usage runs ahead of an even burn rate and will exhaust the window early.
nonisolated struct QuotaPace: Sendable, Equatable {
    /// `usedPercent - elapsedPercent`, rounded.
    var deltaPercent: Int
    /// Projected exhaustion time; nil when the window lasts until its reset.
    var runsOutAt: Date?

    /// Windows with less than this share elapsed have no meaningful pace yet.
    nonisolated static let minimumElapsedFraction = 0.03

    nonisolated static func compute(window: QuotaWindow, now: Date = Date()) -> QuotaPace? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        guard let seconds = windowSeconds(for: window, resetsAt: resetsAt), seconds > 0 else { return nil }
        let remainingSeconds = resetsAt.timeIntervalSince(now)
        let elapsed = max(0, min(1, 1 - remainingSeconds / Double(seconds)))
        guard elapsed >= minimumElapsedFraction else { return nil }

        let used = max(0, min(1, window.usedPercent / 100))
        let delta = Int(((used - elapsed) * 100).rounded())

        var runsOutAt: Date?
        if used > elapsed, used > 0, used < 1 {
            let rate = used / (elapsed * Double(seconds)) // fraction per second
            let secondsLeft = (1 - used) / rate
            let projected = now.addingTimeInterval(secondsLeft)
            if projected < resetsAt { runsOutAt = projected }
        } else if used >= 1 {
            runsOutAt = now
        }
        return QuotaPace(deltaPercent: delta, runsOutAt: runsOutAt)
    }

    /// Explicit length, then the kind default, then a calendar month ending at
    /// the reset for monthly windows.
    nonisolated static func windowSeconds(for window: QuotaWindow, resetsAt: Date) -> Int? {
        if let seconds = window.windowSeconds, seconds > 0 { return seconds }
        if let seconds = window.kind.defaultSeconds { return seconds }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let start = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        let seconds = resetsAt.timeIntervalSince(start)
        return seconds > 0 ? Int(seconds.rounded()) : nil
    }
}
