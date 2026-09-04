import Foundation
import UserNotifications

/// Posts local notifications when a quota lane crosses 20% left, hits 0, or
/// resets. Runs only on fresh API snapshots (never on cache or CLI fallback).
@MainActor
final class QuotaNotifier {
    static let shared = QuotaNotifier()

    private enum Event: String {
        case low
        case exhausted
        case reset
    }

    /// Events already posted for the current window, keyed by account | kind | event.
    private var posted: Set<String> = []
    private var authorization: Bool?

    func evaluate(account: MonitoredAccount, previous: QuotaSnapshot?, next: QuotaSnapshot) {
        guard SettingsStore.shared.quotaNotifications else { return }
        let title = "\(account.descriptor.displayName) · \(account.shortTitle(index: 0, privacy: SettingsStore.shared.privacyMode))"

        for window in next.allWindows {
            let before = previous?.window(window.kind)
            let key = { (event: Event) in "\(account.id.raw)|\(window.kind.rawValue)|\(event.rawValue)" }
            let remaining = window.remainingPercent
            let label = window.kind.shortLabel

            // A window that moved its reset forward and regained quota has restarted.
            if let before,
               [.weekly, .monthly, .fiveHour].contains(window.kind),
               let previousReset = before.resetsAt, let nextReset = window.resetsAt,
               nextReset.timeIntervalSince(previousReset) > 3600,
               remaining - before.remainingPercent >= 30 {
                posted.remove(key(.low))
                posted.remove(key(.exhausted))
                post(
                    id: key(.reset),
                    title: title,
                    body: tr("\(label) quota reset · \(Int(remaining.rounded()))% left", "\(label) 额度已重置 · 剩余 \(Int(remaining.rounded()))%")
                )
                continue
            }

            let previousRemaining = before?.remainingPercent ?? 100
            if remaining <= 0, previousRemaining > 0 {
                post(
                    id: key(.exhausted),
                    title: title,
                    body: tr("\(label) quota exhausted · \(formatResetHint(window.resetsAt))", "\(label) 额度已用尽 · \(formatResetHint(window.resetsAt))")
                )
            } else if remaining <= 20, previousRemaining > 20 {
                post(
                    id: key(.low),
                    title: title,
                    body: tr("\(label) \(Int(remaining.rounded()))% left · \(formatResetHint(window.resetsAt))", "\(label) 剩余 \(Int(remaining.rounded()))% · \(formatResetHint(window.resetsAt))")
                )
            }
        }
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
