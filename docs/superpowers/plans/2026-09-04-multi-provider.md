# Multi-Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn cc-bar into a descriptor-driven multi-provider monitor (Codex, Claude Code, Kimi Code, GLM Coding Plan, Ollama Cloud) whose third-party accounts are discovered from ccpm profiles.

**Architecture:** `Provider` + static `ProviderDescriptor` table; `MonitoredAccount` list replaces the five per-source dictionary sets in `AppState`; one `QuotaFetcher` dispatches by credential kind; UI iterates accounts grouped by provider. ccpm gains an explicit `provider` field and injects `ANTHROPIC_AUTH_TOKEN` for non-Anthropic providers.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (Xcode project, zero dependencies, macOS 14+); Go 1.2x (ccpm, cobra, go-keyring).

**Spec:** `docs/superpowers/specs/2026-09-04-multi-provider-design.md`

## Global Constraints

- Code, comments, identifiers, commit messages: English only.
- No new third-party dependencies in cc-bar; Keychain via `/usr/bin/security` for foreign items, `SecItem*` for cc-bar-owned items.
- Codex is always ordered before Claude; provider order is `Provider.allCases`.
- Never clear a displayable snapshot on network failure; keep the 60s throttle and 10-minute 429 backoff per account.
- Local work only: no commits, no pushes.
- Persisted formats bump versions (`quota-cache` v2, `quota-history` v2, `usage-rollup` / `scan-state` v5); old files are discarded, never migrated.

---

## Part A · ccpm fork (`~/Code/claude-code-profile-manager`)

### Task A1: Provider field + validation

**Files:** Modify `ccpm/internal/config/config.go`, `ccpm/internal/config/config_test.go`.

**Produces:** `ProviderAnthropic/Kimi/GLM/Ollama` consts, `ProfileConfig.Provider`, `(ProfileConfig).ProviderName()`, `ValidateProvider(runtime, provider string) error`, `ProviderDefaultBaseURL(provider string) string`, `AddProfileForRuntime` gains a `provider` argument (existing call sites pass `""`).

- [ ] Test: empty provider resolves to anthropic; `ValidateProvider("codex","kimi")` errors; `ValidateProvider("claude","glm")` ok; unknown provider errors.
- [ ] Implement; `go test ./internal/config/...`.

### Task A2: Launch env injection

**Files:** Modify `ccpm/internal/claude/claude.go` (`execEnv`, `Exec`), `ccpm/cmd/run.go`, `ccpm/cmd/env.go`, tests.

**Produces:** `execEnv(profileDir, apiKey, provider string, profileEnv, extraEnv)`; anthropic → `ANTHROPIC_API_KEY`, else → `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` unset. `ANTHROPIC_AUTH_TOKEN` added to `reservedEnvKeys`.

- [ ] Test `execEnv` both branches; test `env set ANTHROPIC_AUTH_TOKEN=x` rejected.
- [ ] Implement; `go test ./...`.

### Task A3: `ccpm add --provider` + list column

**Files:** Modify `ccpm/cmd/add.go`, `ccpm/cmd/list.go`, `ccpm/cmd/add_test.go` (new if absent), `README.md`.

- [ ] `--provider` flag (default `anthropic`); non-anthropic forces runtime claude + auth api_key, skips `pickAuthMethod`, prompt text per provider, writes `Env["ANTHROPIC_BASE_URL"]` from `ProviderDefaultBaseURL` when absent, prints the `ANTHROPIC_MODEL` hint.
- [ ] `ccpm list` prints a PROVIDER column for claude profiles (`-` for codex).
- [ ] Test: non-interactive stdin `add kimi-work --provider kimi` with the memory keystore writes provider + base URL; `add x --runtime codex --provider kimi` errors.
- [ ] README: document `--provider`, the base URL table, and the AUTH_TOKEN injection. `go test ./...`, `go vet ./...`.

---

## Part B · cc-bar core (`~/Code/cc-bar`)

### Task B1: Provider model

**Files:** Create `Core/Providers/Provider.swift`, `Core/Providers/MonitoredAccount.swift`. Modify `Main/DesignSystem.swift` (accent per provider).

**Produces:** `Provider`, `QuotaWindowKind`, `ProviderDescriptor` (+ `.all`, `Provider.descriptor`), `AccountSource`, `AccountID`, `AccountCredential`, `AccountIdentity`, `MonitoredAccount`, `Provider.accent: Color`.

### Task B2: Quota models + clients

**Files:** Rewrite `Core/Quota/QuotaModels.swift`; adapt `CodexQuotaClient.swift`, `ClaudeQuotaClient.swift`, `ClaudeCLIFallbackQuotaClient.swift`; create `Core/Quota/KimiQuotaClient.swift`, `GLMQuotaClient.swift`, `OllamaCloudQuotaClient.swift`, `QuotaPace.swift`; create `Core/Credentials/CCPMKeystore.swift`, `OllamaCookieStore.swift`.

**Produces:** `QuotaWindow{kind,usedPercent,resetsAt,windowSeconds,detail}`, `QuotaSnapshot{provider,primary,secondary,extra,planType,fetchedAt}`; `KimiQuotaClient.parse(data:now:) throws -> QuotaSnapshot`, `GLMQuotaClient.parse(...)`, `OllamaCloudQuotaClient.parse(html:now:) throws -> QuotaSnapshot`, each with `fetch(...) async -> Result<QuotaSnapshot, QuotaError>`; `QuotaPace.compute(window:now:) -> QuotaPace?`; `CCPMKeystore.apiKey(profile:) -> String?` (+ `decode(_:)`); `OllamaCookieStore.load(profile:) / save(_:profile:) / delete(profile:)`.

- [ ] Selfcheck fixtures for Kimi, GLM (single limit / 5h+weekly / with MCP / implausible 5h reset), Ollama (new page / legacy page / signed-out), keystore prefixes, pace cases.

### Task B3: Discovery + refresh engine + AppState

**Files:** Modify `Core/Credentials/CCPMProfiles.swift` (add `provider`, `env` to `CCPMProfileDescriptor`; keep Claude keychain helpers); create `Core/Providers/AccountCatalog.swift`, `Core/Quota/QuotaFetcher.swift`; rewrite `Core/AppState.swift`; rewrite `Core/Storage/QuotaCache.swift` (v2), `Core/Storage/QuotaHistoryStore.swift` (v2 keys), `Core/Storage/Settings.swift` (provider sets, `menuBarMode`, migration); adapt `Core/Quota/ServiceStatusClient.swift` callers.

**Produces:** `AccountCatalog.discover() -> [MonitoredAccount]` (nonisolated, runs off-main); `QuotaFetcher.fetch(account:reason:) async -> Result<(QuotaSnapshot, QuotaSnapshotSource), QuotaError>`; `AppState.accounts / quota / serviceStatus / todayCost`, `accounts(for:)`, `presentProviders`, `monitorSnapshot(for:)`, `quotaState(for:)`, `refreshQuotas(reason:)`, `refreshNow()`, `bootstrap()`, `reloadImportedCodexAccounts()`, imported-account mutators kept with the same names; `SettingsStore.enabledProviders / menuBarProviders / floatingProviders: Set<Provider>`, `menuBarMode: MenuBarMode`, `isEnabled(_:)`, `effectiveMenuBarProviders / effectiveFloatingProviders`.

### Task B4: Usage scanning per account

**Files:** Modify `Core/Usage/UsageModels.swift`, `UsageAggregator.swift`, `UsageService.swift`, `ClaudeJSONLScanner.swift`, `CodexJSONLScanner.swift`, `Core/Storage/ScanCache.swift` (v5).

**Produces:** `UsageEntry / UsageBucket {accountId: String, provider: Provider, ...}`; `UsageAggregator.totals(provider:from:to:)`, `totals(accountId:from:to:)`, `todayCost(accountId:)`, `todayCost(provider:)`, `modelRows(provider:from:to:)`, `dayBuckets(...)`; `UsageService.scanNow()` reads `appState.accounts`.

### Task B5: Xcode project + selfcheck + build

**Files:** Modify `ccbar.xcodeproj/project.pbxproj` (add/remove file refs); create `scripts/selfcheck.sh`, `scripts/selfcheck/main.swift`; copy `Resources/Logos/{kimi,glm,ollama}.svg` from CodexBar.

- [ ] `scripts/selfcheck.sh` passes.
- [ ] `xcodebuild -project ccbar.xcodeproj -scheme CCBar -configuration Debug build` passes (UI files temporarily adapted minimally if needed before Part C).

---

## Part C · cc-bar UI (`~/Code/cc-bar`)

### Task C1: Popover

**Files:** Rewrite `MenuBar/PopoverRootView.swift`; create `MenuBar/ProviderSection.swift`, `MenuBar/CompactAccountRow.swift`; delete `MenuBar/CodexAccountsSection.swift`, `ClaudeAccountsSection.swift`, `MenuBarLabelFormatter.swift`.

- [ ] Header / risk banner / state dot iterate `appState.quota`.
- [ ] `ProviderSection(provider:)`: single account → `ServiceBlockView`; multiple → header + first block + compact rows with tap-to-expand.
- [ ] `ServiceBlockView(account:state:primaryFirst:)`: detail text, tokens instead of cost when `!supportsCost`, pace line, extra windows.

### Task C2: Menu bar + HUD

**Files:** Modify `MenuBar/MenuBarLabel.swift`, `Floating/FloatingContentView.swift`.

- [ ] Segments from `effectiveMenuBarProviders ∩ presentProviders`; `lowestOnly` mode; HUD rows likewise.

### Task C3: Settings + onboarding

**Files:** Modify `Settings/SettingsRootView.swift`, rewrite `Settings/CCPMProfilesView.swift`, adapt `Settings/ImportedCodexAccountsView.swift`, `Onboarding/OnboardingView.swift`.

- [ ] Accounts group generated from `Provider.allCases`; unified ccpm list with Ollama cookie sheet; menu bar / floating groups generated; onboarding detect rows per provider.

### Task C4: Stats

**Files:** Modify `Main/StatsView.swift`.

- [ ] Service filter from `presentProviders`; cost KPIs respect `supportsCost`; ring rows per provider; timeline per account; breakdown gains provider/account columns.

### Task C5: Docs + final build

**Files:** Modify `docs/产品需求.md`, `docs/技术实现.md`, `docs/界面布局.md`, `docs/设计风格.md`, `README.md`.

- [ ] Docs describe providers, ccpm mapping table, Ollama cookie flow, persistence versions, settings keys.
- [ ] `scripts/selfcheck.sh` and `xcodebuild` both pass; run the app once and check the manual acceptance list in spec §6.3.
