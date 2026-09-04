import Foundation

// Minimal runnable check for the pure logic that has no UI: provider parsers,
// pace maths and the ccpm keystore decoder. Run via scripts/selfcheck.sh.

var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func approx(_ a: Double?, _ b: Double, tolerance: Double = 0.5) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let iso = ISO8601DateFormatter()

// MARK: Codex

let codexWeeklyOnly = """
{"plan_type": "pro", "rate_limit": {"allowed": true, "primary_window": {"used_percent": 30, "limit_window_seconds": 604800, "reset_after_seconds": 230296}, "secondary_window": null}}
"""
do {
    let snapshot = try CodexQuotaClient.parse(data: Data(codexWeeklyOnly.utf8), now: now)
    check(snapshot.planType == "pro", "codex plan type")
    check(snapshot.primary?.kind == .weekly, "codex weekly-only primary is labelled weekly, not 5h")
    check(snapshot.secondary == nil, "codex weekly-only has no secondary")
    check(approx(snapshot.primary?.usedPercent, 30), "codex weekly-only percent")
    check(abs((snapshot.primary?.resetsAt?.timeIntervalSince(now) ?? 0) - 230_296) < 1, "codex reset_after_seconds anchored to now")
} catch {
    check(false, "codex weekly-only parse threw \(error)")
}

let codexSwapped = """
{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_at": 1788765046}, "secondary_window": {"used_percent": 55, "limit_window_seconds": 18000, "reset_at": 1788552750}}}
"""
do {
    let snapshot = try CodexQuotaClient.parse(data: Data(codexSwapped.utf8), now: now)
    check(snapshot.primary?.kind == .fiveHour && approx(snapshot.primary?.usedPercent, 55), "codex session lane sorts first even when the API lists it second")
    check(snapshot.secondary?.kind == .weekly && approx(snapshot.secondary?.usedPercent, 10), "codex weekly lane second")
} catch {
    check(false, "codex swapped parse threw \(error)")
}
check(CodexQuotaClient.kind(forWindowSeconds: nil, fallback: .fiveHour) == .fiveHour, "codex kind falls back when window length missing")
check(CodexQuotaClient.kind(forWindowSeconds: 2_592_000, fallback: .fiveHour) == .monthly, "codex 30-day window is monthly")

// MARK: Claude

let claudeJSON = """
{
  "five_hour": {"utilization": 12.5, "resets_at": "2027-01-06T13:33:02Z"},
  "seven_day": {"utilization": 40, "resets_at": "2027-01-09T15:23:13.716839300Z"},
  "seven_day_opus": {"utilization": 20, "resets_at": "2027-01-09T15:23:13Z"},
  "extra_usage": {"is_enabled": true, "monthly_limit": 200000, "used_credits": 1234, "utilization": 0.617, "currency": "USD"}
}
"""
do {
    let snapshot = try ClaudeQuotaClient.parse(data: Data(claudeJSON.utf8), now: now)
    check(snapshot.primary?.kind == .fiveHour && approx(snapshot.primary?.usedPercent, 12.5), "claude primary is 5h")
    check(snapshot.primary?.windowSeconds == 18_000, "claude 5h window seconds default")
    check(snapshot.secondary?.kind == .weekly && approx(snapshot.secondary?.usedPercent, 40), "claude secondary is weekly")
    check(snapshot.extra.first?.kind == .weeklyOpus && approx(snapshot.extra.first?.usedPercent, 20), "claude opus extra lane")
    let extraUsage = snapshot.extra.first { $0.kind == .extraUsage }
    check(extraUsage != nil, "claude extra usage lane present when enabled")
    check(approx(extraUsage?.usedPercent, 0.617, tolerance: 0.01), "claude extra usage utilization used as percent")
    check(extraUsage?.detail == "$12.34 / $2000.00", "claude extra usage cents converted to dollars")
    check(extraUsage?.windowSeconds == nil && extraUsage?.resetsAt == nil, "claude extra usage has no window or reset")
} catch {
    check(false, "claude parse threw \(error)")
}

let claudeNoExtra = """
{"five_hour": {"utilization": 5}, "seven_day": {"utilization": 9}, "extra_usage": {"is_enabled": false, "monthly_limit": 200000, "used_credits": 0}}
"""
do {
    let snapshot = try ClaudeQuotaClient.parse(data: Data(claudeNoExtra.utf8), now: now)
    check(snapshot.extra.isEmpty, "claude disabled extra usage yields no lane")
} catch {
    check(false, "claude no-extra parse threw \(error)")
}

let claudeFallbackPercent = """
{"five_hour": {"utilization": 5}, "extra_usage": {"is_enabled": true, "monthly_limit": 10000, "used_credits": 2500}}
"""
do {
    let snapshot = try ClaudeQuotaClient.parse(data: Data(claudeFallbackPercent.utf8), now: now)
    check(approx(snapshot.extra.first?.usedPercent, 25), "claude extra usage percent from used/limit when utilization missing")
} catch {
    check(false, "claude fallback percent parse threw \(error)")
}

// MARK: Kimi

let kimiJSON = """
{
  "usage": {"limit": "2048", "used": "214", "remaining": "1834", "resetTime": "2027-01-09T15:23:13.716839300Z"},
  "limits": [{
    "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
    "detail": {"limit": "200", "used": 139, "remaining": "61", "resetTime": "2027-01-06T13:33:02Z"}
  }]
}
"""
do {
    let snapshot = try KimiQuotaClient.parse(data: Data(kimiJSON.utf8), now: now)
    check(snapshot.provider == .kimi, "kimi provider")
    check(snapshot.primary?.kind == .fiveHour, "kimi primary is 5h rate limit")
    check(approx(snapshot.primary?.usedPercent, 69.5), "kimi 5h used percent")
    check(snapshot.primary?.windowSeconds == 18_000, "kimi 5h window seconds")
    check(snapshot.primary?.detail == "139/200 requests", "kimi 5h detail")
    check(snapshot.secondary?.kind == .weekly, "kimi secondary is weekly requests")
    check(approx(snapshot.secondary?.usedPercent, 10.45), "kimi weekly used percent")
    check(snapshot.secondary?.resetsAt != nil, "kimi weekly reset parsed")
} catch {
    check(false, "kimi parse threw \(error)")
}
check(KimiQuotaClient.usageURL(baseURL: URL(string: "https://api.kimi.com/coding/")!).absoluteString == "https://api.kimi.com/coding/v1/usages",
      "kimi usage url from base url")

// MARK: GLM

let glmDual = """
{"success": true, "code": 200, "data": {"planName": "Pro", "limits": [
  {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 40, "usage": 1000, "currentValue": 400, "nextResetTime": \(Int((now.timeIntervalSince1970 + 3600) * 1000))},
  {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 12, "nextResetTime": \(Int((now.timeIntervalSince1970 + 3 * 86400) * 1000))},
  {"type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 3, "usage": 100, "remaining": 97}
]}}
"""
do {
    let snapshot = try GLMQuotaClient.parse(data: Data(glmDual.utf8), now: now)
    check(snapshot.planType == "Pro", "glm plan name")
    check(snapshot.primary?.kind == .fiveHour, "glm shortest token limit is primary 5h")
    check(approx(snapshot.primary?.usedPercent, 40), "glm 5h percent from usage/currentValue")
    check(snapshot.primary?.resetsAt != nil, "glm 5h reset kept when plausible")
    check(snapshot.secondary?.kind == .weekly, "glm weekly is secondary")
    check(approx(snapshot.secondary?.usedPercent, 12), "glm weekly percent")
    check(snapshot.extra.first?.kind == .mcp, "glm TIME_LIMIT becomes mcp extra")
    check(approx(snapshot.extra.first?.usedPercent, 3), "glm mcp percent from usage/remaining")
} catch {
    check(false, "glm dual parse threw \(error)")
}

let glmSingle = """
{"success": true, "code": 200, "data": {"limits": [
  {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 55, "nextResetTime": \(Int((now.timeIntervalSince1970 + 10 * 3600) * 1000))}
]}}
"""
do {
    let snapshot = try GLMQuotaClient.parse(data: Data(glmSingle.utf8), now: now)
    check(snapshot.primary?.kind == .fiveHour, "glm single credit limit is primary")
    check(snapshot.secondary == nil, "glm single limit has no secondary")
    check(snapshot.primary?.resetsAt == nil, "glm implausible 5h reset dropped")
    check(approx(snapshot.primary?.usedPercent, 55), "glm percentage fallback")
} catch {
    check(false, "glm single parse threw \(error)")
}

do {
    _ = try GLMQuotaClient.parse(data: Data("{\"success\": false, \"code\": 401, \"msg\": \"bad key\"}".utf8), now: now)
    check(false, "glm rejected response should throw")
} catch let error as QuotaError {
    check(error.httpStatusCode == 401, "glm 401 surfaces as auth failure")
} catch {
    check(false, "glm rejected response wrong error type")
}

// MARK: Ollama Cloud

let ollamaNew = """
<html><body>
<span>Included usage</span> <span class="badge">Pro</span>
<div><h3>Monthly usage</h3><p>$7.50 of $60 used</p><span>Resets in <time data-time="2027-02-01T00:00:00Z">4 days</time></span></div>
<div><h3>Weekly usage</h3><p>25% used</p><span data-time="2027-01-10T00:00:00Z"></span></div>
</body></html>
"""
do {
    let snapshot = try OllamaCloudQuotaClient.parse(html: ollamaNew, now: now)
    check(snapshot.planType == "Pro", "ollama plan badge")
    check(snapshot.primary?.kind == .monthly, "ollama monthly is primary")
    check(approx(snapshot.primary?.usedPercent, 12.5), "ollama monthly dollars to percent")
    check(snapshot.primary?.detail == "$7.50 of $60", "ollama monthly detail")
    check(snapshot.primary?.resetsAt == iso.date(from: "2027-02-01T00:00:00Z"), "ollama monthly reset")
    check(snapshot.secondary?.kind == .weekly, "ollama weekly secondary")
    check(approx(snapshot.secondary?.usedPercent, 25), "ollama weekly percent")
} catch {
    check(false, "ollama new page parse threw \(error)")
}

let ollamaLegacy = """
<html><body>
<span>Cloud Usage</span><span>Free</span>
<div>Session usage <div style="width: 60%"></div><span data-time="2027-01-05T05:00:00Z"></span></div>
<div>Weekly usage <p>10% used</p></div>
</body></html>
"""
do {
    let snapshot = try OllamaCloudQuotaClient.parse(html: ollamaLegacy, now: now)
    check(snapshot.primary?.kind == .fiveHour, "ollama legacy session is primary")
    check(approx(snapshot.primary?.usedPercent, 60), "ollama legacy width percent")
    check(snapshot.primary?.windowSeconds == 18_000, "ollama legacy session window")
    check(approx(snapshot.secondary?.usedPercent, 10), "ollama legacy weekly")
} catch {
    check(false, "ollama legacy parse threw \(error)")
}

let ollamaSignedOut = """
<html><body><h1>Sign in to Ollama</h1><form action="/signin"><input type="email" name="email"><input type="password" name="password"></form></body></html>
"""
do {
    _ = try OllamaCloudQuotaClient.parse(html: ollamaSignedOut, now: now)
    check(false, "ollama signed-out page should throw")
} catch let error as QuotaError {
    check(error.httpStatusCode == 401, "ollama signed-out page is 401")
} catch {
    check(false, "ollama signed-out wrong error type")
}
check(OllamaCloudQuotaClient.isSignInRedirect(URL(string: "https://ollama.com/signin?next=/settings")), "ollama signin redirect detected")
check(!OllamaCloudQuotaClient.isSignInRedirect(URL(string: "https://ollama.com/settings")), "ollama settings url is not a redirect")

// MARK: ccpm keystore decoding

check(CCPMKeystore.decode("go-keyring-base64:c2stdGVzdA==") == "sk-test", "keystore base64 prefix")
check(CCPMKeystore.decode("go-keyring-encoded:736b2d74657374") == "sk-test", "keystore hex prefix")
check(CCPMKeystore.decode("plain-value") == "plain-value", "keystore raw passthrough")

// MARK: Pace

let halfWay = QuotaWindow(kind: .fiveHour, usedPercent: 50, resetsAt: now.addingTimeInterval(9_000), windowSeconds: 18_000)
let onPace = QuotaPace.compute(window: halfWay, now: now)
check(onPace?.deltaPercent == 0, "pace on pace at half window half used")
check(onPace?.runsOutAt == nil, "pace on pace has no runs-out")

let ahead = QuotaWindow(kind: .fiveHour, usedPercent: 80, resetsAt: now.addingTimeInterval(9_000), windowSeconds: 18_000)
let aheadPace = QuotaPace.compute(window: ahead, now: now)
check(aheadPace?.deltaPercent == 30, "pace ahead delta")
if let runsOut = aheadPace?.runsOutAt {
    // 80% in 9000s -> full at 11250s elapsed -> 2250s from now.
    check(abs(runsOut.timeIntervalSince(now) - 2_250) < 1, "pace ahead runs-out projection")
} else {
    check(false, "pace ahead should project runs-out")
}

let behind = QuotaWindow(kind: .fiveHour, usedPercent: 20, resetsAt: now.addingTimeInterval(9_000), windowSeconds: 18_000)
check(QuotaPace.compute(window: behind, now: now)?.deltaPercent == -30, "pace behind delta")

let fresh = QuotaWindow(kind: .fiveHour, usedPercent: 5, resetsAt: now.addingTimeInterval(17_900), windowSeconds: 18_000)
check(QuotaPace.compute(window: fresh, now: now) == nil, "pace nil under 3% elapsed")

let monthly = QuotaWindow(kind: .monthly, usedPercent: 50, resetsAt: now.addingTimeInterval(15 * 86400), windowSeconds: nil)
let monthlySeconds = QuotaPace.windowSeconds(for: monthly, resetsAt: monthly.resetsAt!)
check((monthlySeconds ?? 0) >= 28 * 86400 && (monthlySeconds ?? 0) <= 31 * 86400, "pace monthly window inferred from reset")

let weeklyDefault = QuotaWindow(kind: .weekly, usedPercent: 50, resetsAt: now.addingTimeInterval(3.5 * 86400), windowSeconds: nil)
check(QuotaPace.compute(window: weeklyDefault, now: now)?.deltaPercent == 0, "pace uses kind default seconds")

// MARK: Snapshot aggregation

let a = QuotaSnapshot(provider: .claude,
                      primary: QuotaWindow(kind: .fiveHour, usedPercent: 30),
                      secondary: QuotaWindow(kind: .weekly, usedPercent: 10),
                      extra: [QuotaWindow(kind: .weeklyOpus, usedPercent: 5)],
                      planType: nil, fetchedAt: now)
let b = QuotaSnapshot(provider: .claude,
                      primary: QuotaWindow(kind: .fiveHour, usedPercent: 70),
                      secondary: QuotaWindow(kind: .weekly, usedPercent: 5),
                      extra: [QuotaWindow(kind: .weeklyOpus, usedPercent: 60)],
                      planType: nil, fetchedAt: now)
let merged = QuotaSnapshot.mostConstrained([a, b])
check(approx(merged?.primary?.usedPercent, 70), "aggregate picks most used primary")
check(approx(merged?.secondary?.usedPercent, 10), "aggregate picks most used secondary")
check(approx(merged?.extra.first?.usedPercent, 60), "aggregate picks most used extra per kind")
check(QuotaSnapshot.mostConstrained([]) == nil, "aggregate of nothing is nil")

// MARK: Account ids

check(AccountID(provider: .kimi, source: .ccpm(profile: "work")).raw == "kimi:ccpm:work", "account id format")
check(AccountID(provider: .codex, source: .importedCodex(id: "acc:user")).raw == "codex:imported:acc:user", "imported account id")

if failures > 0 {
    print("\(failures) check(s) failed")
    exit(1)
}
print("all checks passed")
