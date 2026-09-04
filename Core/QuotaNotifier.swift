import Foundation
import UserNotifications

/// Posts local notifications when a quota lane crosses 10% left, hits 0, or resets.
/// Callers only feed fresh API snapshots (never cache or CLI fallback).
@MainActor
final class QuotaNotifier {
    static let shared = QuotaNotifier()

    static let lowThreshold: Double = 10

    private enum Event: String {
        case low
        case exhausted
        case reset
    }

    /// Last observed lanes per account key, keyed by limit id.
    private var lastLanes: [String: [String: QuotaWindow]] = [:]
    /// Events already posted for the current window: account | limit id | event.
    private var posted: Set<String> = []
    private var authorization: Bool?

    func observe(key: String, label: String, snapshot: QuotaSnapshot) {
        let previousLanes = lastLanes[key] ?? [:]
        var nextLanes: [String: QuotaWindow] = [:]
        defer { lastLanes[key] = nextLanes }

        guard SettingsStore.shared.quotaNotificationsEnabled else {
            for limit in snapshot.allLimits { nextLanes[limit.id] = limit.window }
            return
        }

        for limit in snapshot.allLimits {
            let window = limit.window
            nextLanes[limit.id] = window
            let before = previousLanes[limit.id]
            let remaining = window.remainingPercent
            let eventKey = { (event: Event) in "\(key)|\(limit.id)|\(event.rawValue)" }
            let lane = limit.laneTitle

            // Reset: regained most of the quota, or the reset date moved forward and quota came back.
            if let before {
                let regained = remaining - before.remainingPercent
                let movedForward = zip(before.resetsAt, window.resetsAt)
                    .map { $1.timeIntervalSince($0) > 3600 } ?? false
                if (before.remainingPercent < 50 && remaining >= 90) || (movedForward && regained >= 30) {
                    posted.remove(eventKey(.low))
                    posted.remove(eventKey(.exhausted))
                    posted.remove(eventKey(.reset))
                    post(
                        id: eventKey(.reset),
                        title: label,
                        body: tr("\(lane) quota reset · \(Int(remaining.rounded()))% left",
                                 "\(lane) 额度已重置 · 剩余 \(Int(remaining.rounded()))%")
                    )
                    continue
                }
            }

            let previousRemaining = before?.remainingPercent ?? 100
            if remaining <= 0, previousRemaining > 0 {
                post(
                    id: eventKey(.exhausted),
                    title: label,
                    body: tr("\(lane) quota exhausted · \(resetHint(window.resetsAt))",
                             "\(lane) 额度已用尽 · \(resetHint(window.resetsAt))")
                )
            } else if remaining <= Self.lowThreshold, previousRemaining > Self.lowThreshold {
                post(
                    id: eventKey(.low),
                    title: label,
                    body: tr("\(lane) \(Int(remaining.rounded()))% left · \(resetHint(window.resetsAt))",
                             "\(lane) 剩余 \(Int(remaining.rounded()))% · \(resetHint(window.resetsAt))")
                )
            }
        }
    }

    private func resetHint(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return tr("reset time unknown", "重置时间未知") }
        let minutes = max(0, Int(resetsAt.timeIntervalSinceNow / 60))
        if minutes < 60 { return tr("resets in \(minutes)m", "\(minutes) 分钟后重置") }
        let hours = minutes / 60
        if hours < 48 { return tr("resets in \(hours)h", "\(hours) 小时后重置") }
        return tr("resets in \(hours / 24)d", "\(hours / 24) 天后重置")
    }

    private func post(id: String, title: String, body: String) {
        guard posted.insert(id).inserted else { return }
        Task { @MainActor in
            guard await authorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // A fixed identifier per event replaces any pending copy instead of stacking.
            let request = UNNotificationRequest(identifier: "ccbar.quota.\(id)", content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                print("[QuotaNotifier] add failed: \(error)")
            }
        }
    }

    private func authorized() async -> Bool {
        if let authorization { return authorization }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorization = true
        case .denied:
            authorization = false
        default:
            authorization = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return authorization ?? false
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
