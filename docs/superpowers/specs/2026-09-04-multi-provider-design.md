# cc-bar 多 Provider 设计（Kimi / GLM / Ollama Cloud + ccpm 联动）

> 日期：2026-09-04。状态：已批准，实施中。
> 目标：参考 CodexBar 的 descriptor 驱动架构，把 cc-bar 从「Codex + Claude 两套硬编码」改成「统一账号模型 + 按 provider 分发」，并通过 ccpm profile 自动发现 Kimi Code、GLM Coding Plan、Ollama Cloud 三家账号。

---

## 0. 决策记录

| 决策 | 结论 |
|---|---|
| 第三方账号来源 | 只走 ccpm profile 自动发现，cc-bar 不提供独立填 key 的入口 |
| provider 标识 | ccpm `config.json` 显式 `provider` 字段；cc-bar 不按 URL 推断 |
| Ollama 形态 | Ollama Cloud（ollama.com）。**2026-09-05 修订**：主账号从本机 `~/.ollama/id_ed25519` 自动识别，用与 Ollama 桌面端相同的密钥签名调用 `POST /api/me` 与 `GET /api/usage`，不再需要 Cookie；ccpm ollama profile 用 API key（Bearer）调同一接口。原「手动粘贴 Cookie 抓 settings 页」方案作废 |
| 架构路线 | Descriptor 驱动的统一账号模型，一次性重写 AppState / Popover；缓存与汇总文件升版触发全量重扫 |
| 代码落点 | `~/Code/cc-bar`、`~/Code/claude-code-profile-manager`；只做本地改动，不提交 |
| 不做 | GLM team scope、Kimi 网页 Cookie 增强、z.ai 全球站余额、Ollama 浏览器导入、App 内登录 |

---

## 1. 数据模型（cc-bar）

### 1.1 Provider 与 descriptor

```swift
enum Provider: String, CaseIterable, Codable, Sendable {
    case codex, claude, kimi, glm, ollama   // fixed display order
}

enum QuotaWindowKind: String, Codable, Sendable {
    case fiveHour, weekly, monthly, weeklyOpus, weeklySonnet, mcp
    var shortLabel: String        // 5H / WK / MO / OPUS / SONNET / MCP
    var defaultSeconds: Int?      // fiveHour 18_000, weekly 604_800, others nil
}

struct ProviderDescriptor: Sendable {
    let id: Provider
    let displayName: String       // Codex / Claude Code / Kimi Code / GLM Coding Plan / Ollama Cloud
    let vendor: String            // OpenAI / Anthropic / Moonshot / Zhipu / Ollama
    let logoName: String          // Resources/Logos/<logoName>.svg
    let fallbackGlyph: String
    let primaryKind: QuotaWindowKind      // ollama: .monthly, others: .fiveHour
    let secondaryKind: QuotaWindowKind?   // all: .weekly
    let supportsCost: Bool                // codex, claude: true; kimi, glm, ollama: false
    let statusPageURL: URL?               // codex, claude only
    let defaultBaseURL: URL?              // kimi, glm, ollama: what ccpm writes into ANTHROPIC_BASE_URL
}
```

`ProviderDescriptor.all: [Provider: ProviderDescriptor]` 是静态表；识别色放在 `DesignSystem` 的 `Provider.accent`。

### 1.2 账号

```swift
enum AccountSource: Hashable, Codable, Sendable {
    case defaultLogin
    case importedCodex(id: String)
    case ccpm(profile: String)
}

struct AccountID: Hashable, Codable, Sendable { let raw: String }  // "<provider>:<source key>"

enum AccountCredential: Sendable {
    case codexOAuth(CodexAccount, writeBack: CodexTokenRefresher.WriteBack)
    case claudeOAuth(ClaudeAccount, storage: ClaudeCredentialStorage)
    case apiKey(String, baseURL: URL)
    case ollamaCookie(cookieHeader: String?, baseURL: URL)
    case unavailable(reason: String)
}

struct AccountIdentity: Sendable, Equatable {
    var email: String?
    var displayName: String?
    var plan: String?
    var profileName: String?
    var profileDir: String?
    var isDefaultProfile: Bool
}

struct MonitoredAccount: Identifiable, Sendable {
    let id: AccountID
    let provider: Provider
    let source: AccountSource
    var identity: AccountIdentity
    var credential: AccountCredential
    var usageRoots: [URL]
    var mirrorsAccount: AccountID?   // reuse another account's quota state (imported / ccpm codex == default)
}
```

### 1.3 额度快照

```swift
struct QuotaWindow: Codable, Sendable, Equatable {
    var kind: QuotaWindowKind
    var usedPercent: Double
    var resetsAt: Date?
    var windowSeconds: Int?
    var detail: String?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    var provider: Provider
    var primary: QuotaWindow?
    var secondary: QuotaWindow?
    var extra: [QuotaWindow]
    var planType: String?
    var fetchedAt: Date
}
```

「5H/WK」切换改为主副窗口互换，标签从 `kind.shortLabel` 取。Codex / Claude 显示不变；Ollama 显示 MO / WK。

### 1.4 AppState

```swift
@Observable @MainActor final class AppState {
    var accounts: [MonitoredAccount] = []
    var quota: [AccountID: AccountQuotaState] = [:]
    var serviceStatus: [Provider: ServiceStatus] = [:]
    var todayCost: [AccountID: Decimal] = [:]
    var quotaHistory = QuotaHistoryPayload()
    var importedCodexAccounts: [ImportedCodexAccount] = []   // management list for Settings
    var mainTab: MainTab
    var shouldShowOnboarding: Bool
    let usageService: UsageService
}

struct AccountQuotaState: Sendable, Equatable {
    var snapshot: QuotaSnapshot?
    var source: QuotaSnapshotSource?
    var error: String?
    var refresh = QuotaRefreshState()
}
```

派生查询：`accounts(for:)`、`presentProviders`（有账号的 provider，按固定顺序）、`monitorSnapshot(for provider:)`（同 provider 各账号每个窗口取剩余最低者，即现有 Claude 聚合规则推广）、`quotaState(for account:)`（先解 `mirrorsAccount`）。

### 1.5 发现流程 `AccountCatalog.discover()`

每次刷新前重跑，替换 `loadCodex / loadClaude / reloadImportedCodexAccounts / reloadCCPMCodexProfiles / reloadCCPMClaudeProfiles`。

1. 默认 Codex：`~/.codex/auth.json`。默认 Claude：credentials 文件或 Keychain。两者沿用现有读取。
2. 导入 Codex 账号：沿用 `ImportedCodexStore`；与默认 Codex 同身份时 `mirrorsAccount = codex:default`。
3. ccpm profiles（`~/.ccpm/config.json`，尊重 `CCPM_HOME`）：

| runtime | provider | auth_method | 结果 |
|---|---|---|---|
| codex | — | oauth | Codex OAuth，读 `<dir>/auth.json`；与默认或导入账号同身份时镜像 |
| codex | — | api_key | `.unavailable`（OpenAI API key 无 wham/usage） |
| claude | 缺省 / anthropic | oauth | Claude OAuth，沿用 profile Keychain service 规则 |
| claude | anthropic | api_key | `.unavailable`（只做本地用量） |
| claude | kimi / glm | api_key | key 读 ccpm keystore；baseURL 取 `env.ANTHROPIC_BASE_URL`，缺失用 descriptor 默认 |
| claude | ollama | api_key | ccpm keystore 里的 API key，`Authorization: Bearer`（2026-09-05 修订；原 cookie 方案作废） |
| 其他组合 | | | 忽略并打日志 |

`usageRoots`：默认 Claude → `~/.claude/projects`；默认 Codex → `~/.codex/sessions` + `~/.codex/archived_sessions`；ccpm claude 运行时 → `<dir>/projects`；ccpm codex → `<dir>/sessions` + `<dir>/archived_sessions`；导入 Codex 账号 → 空。

### 1.6 持久化

| 文件 | 变化 |
|---|---|
| `quota-cache.json` | v2：`records: [String: QuotaCacheRecord]`，键 `AccountID.raw` |
| `quota-history-today.json` | v2：`accountKey = AccountID.raw`，字段 `provider`；删除 `QuotaHistoryAccountKind` |
| `usage-rollup.json` / `scan-state.json` | v5：桶键 `(day, accountId, provider, model)`；旧版本直接丢弃触发全量重扫 |
| cc-bar Keychain | 无新增（2026-09-05 修订：Ollama 不再存 cookie） |
| UserDefaults | `showCodex/showClaude` 等布尔对改为 `enabledProviders / menuBarProviders / floatingProviders: Set<Provider>`；新增 `menuBarMode: all | lowestOnly`；首次启动从旧键迁移 |

---

## 2. ccpm fork 改动（Go）

### 2.1 配置

```go
const (
    ProviderAnthropic = "anthropic"
    ProviderKimi      = "kimi"
    ProviderGLM       = "glm"
    ProviderOllama    = "ollama"
)

type ProfileConfig struct {
    // ...existing fields...
    Provider string `json:"provider,omitempty"` // claude runtime only; empty means anthropic
}

func (p ProfileConfig) ProviderName() string // "" -> anthropic
func ValidateProvider(runtime, provider string) error // non-anthropic requires runtime claude
```

Provider 默认 base URL（写入 `Env["ANTHROPIC_BASE_URL"]`，用户已设置则不覆盖）：

| provider | ANTHROPIC_BASE_URL |
|---|---|
| kimi | `https://api.kimi.com/coding/` |
| glm | `https://open.bigmodel.cn/api/anthropic` |
| ollama | `https://ollama.com` |

### 2.2 `ccpm add <name> --provider kimi|glm|ollama|anthropic`

- 非 anthropic 时强制 `runtime = claude`、`auth_method = api_key`，跳过 OAuth 询问，提示语按 provider（"Enter your Kimi Code API key" 等）。
- 保留 import wizard（skills / MCP 等仍可导入）。
- 成功后打印提示：模型名需自行 `ccpm env set ANTHROPIC_MODEL=... --profile <name>`。

### 2.3 启动注入

`claude.execEnv` 增加 `provider` 参数：anthropic 注入 `ANTHROPIC_API_KEY`，其他 provider 注入 `ANTHROPIC_AUTH_TOKEN`（Kimi Code、GLM、Ollama 文档均要求 Bearer）。两者都属于 ccpm 计算值，`ANTHROPIC_AUTH_TOKEN` 加入 `reservedEnvKeys`。

### 2.4 展示

`ccpm list` 增加 PROVIDER 列；`ccpm status` / `auth status` 的 api_key 检查不区分 provider（keystore 有 key 即有效）。

### 2.5 测试

- `config`：`ProviderName` 默认值、`ValidateProvider` 拒绝 codex + kimi。
- `claude.execEnv`：anthropic 走 `ANTHROPIC_API_KEY`，kimi 走 `ANTHROPIC_AUTH_TOKEN` 且不含 `ANTHROPIC_API_KEY`。
- `env set ANTHROPIC_AUTH_TOKEN=...` 被拒。
- `add --provider kimi` 在非交互 stdin 下写出 provider 与默认 base URL。

---

## 3. 额度客户端与映射（cc-bar）

统一入口 `QuotaFetcher.fetch(account:) async -> Result<QuotaSnapshot, QuotaError>` 按 `credential` 分发。刷新调度（60s 节流、429 退避 10 分钟、in-flight 去重、每批最多 3 个并发）从 AppState 的五套副本收敛为一套，按 `AccountID` 键控。

### 3.1 Codex / Claude

沿用 `CodexQuotaClient` / `ClaudeQuotaClient` / `ClaudeCLIFallbackQuotaClient`，只把返回值改为新 `QuotaSnapshot`：`primary = fiveHour`，`secondary = weekly`，Claude 的 Opus / Sonnet 周窗进 `extra`。Token 续期、镜像、委托刷新逻辑不动。

### 3.2 Kimi Code

- `GET {baseHost}/coding/v1/usages`，`Authorization: Bearer <key>`，`Accept: application/json`。`baseHost` 取 `ANTHROPIC_BASE_URL` 的 scheme + host。
- 响应 `usage{limit,used,remaining,resetTime}` 为周请求数配额；`limits[0]{window{duration,timeUnit},detail{...}}` 为 5 小时速率限制。数值字段可能是字符串或数字，两种都接受。
- 映射：`primary = fiveHour(used/limit, resetTime, window)`，`detail = "139/200 requests"`；`secondary = weekly(used/limit, resetTime, 604_800)`，`detail = "214/2048 requests"`。
- 401 → `QuotaError.http(401)`，UI 提示 key 无效。

### 3.3 GLM Coding Plan

- `GET {baseHost}/api/monitor/usage/quota/limit`，Bearer key。`baseHost` 取自 `ANTHROPIC_BASE_URL`（`open.bigmodel.cn` 或 `api.z.ai`）。
- 响应 `{success, code, data{limits[], planName}}`。每个 limit：`type ∈ TOKENS_LIMIT | CREDIT_LIMIT | TIME_LIMIT`，`unit`（1 天、3 小时、5 分钟、6 周），`number`，`percentage`，`usage`，`currentValue`，`remaining`，`nextResetTime`（毫秒）。
- 映射：token / credit 类按窗口长度排序，最短为 `primary`（kind 按窗口长度判：300 分钟 → fiveHour，否则 weekly），最长为 `secondary`；`TIME_LIMIT` 作为 `extra` 的 `mcp` 窗（`unit=5,number=1` 视为月窗）。百分比优先按 `usage` 与 `currentValue/remaining` 计算，否则用 `percentage`。5 小时窗的 reset 若超过当前时间 5 小时零 1 分钟则丢弃 reset，保留百分比。
- `planName` → `planType`。

### 3.4 Ollama Cloud（2026-09-05 修订：密钥签名 API，替代 Cookie 方案）

- 主账号：`~/.ollama/id_ed25519` 存在即视为已安装。`OllamaLocalKey` 解析未加密的 OpenSSH ed25519 私钥，对 `"<METHOD>,<PATH>?ts=<unix>"` 签名，`Authorization: <pubkey>:<sig>`，URL 带同一 `ts`。`POST /api/me` → name / email / plan（401 = 未 `ollama signin`）；`GET /api/usage` → `limits.<window>.usage`（比例），`monthly` 为主 lane，detail 为各模型请求数之和。ccpm ollama profile 走 `Authorization: Bearer <api key>`。
- 以下为作废的 Cookie 方案原文，仅供追溯：

- 无 cookie → `AccountQuotaState.error = "Paste ollama.com cookie in Settings"`，不发请求。
- 有 cookie → `GET https://ollama.com/settings`，请求头：`Cookie`、浏览器 UA、`accept: text/html`。301/302 到 `/signin` 或 200 但页面含登录表单 → `QuotaError.http(401)`，提示 cookie 过期。
- 解析规则移植 CodexBar `OllamaUsageParser`：
  - 计划名：`Included usage</span><span>…</span` 或 `Cloud Usage` 变体。
  - 月窗：`Monthly usage` 段内 `$X of $Y used` → 已用百分比；`data-time="…"` → reset。
  - 周窗：`Weekly usage` 段内 `N% used` 或进度条 `width: N%`。
  - 旧页面的 `Session usage / Hourly usage` 作为 `extra` 的 fiveHour 窗。
- 映射：`primary = monthly`（`windowSeconds` 由 reset 反推一个自然月），`secondary = weekly`，`detail = "$7.50 of $60"`。

### 3.5 ccpm keystore 读取

```
security find-generic-password -s ccpm -a <profile> -w
```

输出前缀 `go-keyring-base64:` → base64 解码；`go-keyring-encoded:` → hex 解码；无前缀原样使用。条目由 `security` CLI 创建，cc-bar 再通过 `security` 读取不触发授权弹窗。

### 3.6 Pace

```swift
struct QuotaPace: Equatable {
    var deltaPercent: Int        // usedPercent - elapsedPercent, positive means ahead of budget
    var runsOutAt: Date?         // only when delta > 0 and projection lands before reset
    static func compute(window: QuotaWindow, now: Date) -> QuotaPace?
}
```

`elapsed = 1 - (resetsAt - now) / windowSeconds`；`windowSeconds` 缺失时用 `kind.defaultSeconds`；monthly 用 reset 反推自然月。窗口已过去不足 3% 时返回 `nil`。文案：`on pace` / `+12% ahead · runs out in 1h20m` / `-8% behind`。

### 3.7 服务状态

`serviceStatus: [Provider: ServiceStatus]`，仅对 `statusPageURL != nil` 的 provider 拉取，调度不变。

---

## 4. 本地用量扫描

- `ClaudeJSONLScanner.scan(root:accountId:provider:previous:seen:)`、`CodexJSONLScanner.scan(roots:accountId:previous:)`，扫描路径来自 `MonitoredAccount.usageRoots`。
- `UsageService.scanNow()` 对 `accounts` 中 `usageRoots` 非空的账号并行扫描（TaskGroup，最多 4 并发），Claude 消息 id 的全局 seen 集合跨账号共享。
- `UsageEntry / UsageBucket` 增加 `accountId: String`、`provider: Provider`，删除 `UsageApp`。
- `UsageAggregator` 提供 `totals(provider:from:to:)`、`totals(accountId:from:to:)`、`todayCost(accountId:)`、`modelRows(provider:...)`。
- 价格表不变：Kimi / GLM / Ollama 模型未命中价格 → cost 0；由 `supportsCost = false` 决定 UI 不显示费用，只显示 token。

---

## 5. UI / UX

### 5.1 Popover（宽 340pt 不变）

- Header 不变（标题、相对时间、状态点、主副窗切换、刷新 / 统计 / 设置 / 退出）。
- 内容按 `presentProviders` 顺序分组。每组：
  - 只有一个账号：直接一个 `ServiceBlockView`（现有完整块）。
  - 多账号：分区标题（`<PROVIDER> ACCOUNTS · n`）+ 第一个账号完整块 + 其余账号 `CompactAccountRow`。
- `CompactAccountRow`：一行 30pt，内容为小 tile、账号名、主窗进度条、主窗百分比、副窗百分比、状态点；点击展开为完整块（`@State expanded: Set<AccountID>`，不持久化）。
- `ServiceBlockView` 改为吃 `MonitoredAccount + AccountQuotaState + ProviderDescriptor`：
  - 主窗大字与进度条同现在；`detail` 存在时替换 "reset" 行右侧的 cost 区（Kimi 显示 `139/200 requests`）。
  - `supportsCost == false` 时隐藏 today / week cost，改显示 today / week tokens。
  - 主窗下新增一行 pace 文案，颜色跟 `deltaPercent` 符号（超前橙、落后与 on pace 次级色）。
  - `extra` 窗口以副窗样式逐行列出（Opus / Sonnet / MCP）。
- 风险横幅、header 状态点、相对时间全部改为遍历 `quota` 字典。
- 空状态：无任何账号 → "未发现账号 / 到 ccpm 或终端登录"。

### 5.2 菜单栏

- 段按 `menuBarProviders ∩ presentProviders` 顺序绘制，每段 logo + 该 provider 聚合快照的主窗（或副窗、或两者）百分比。
- 新设置 `menuBarMode`：`all`（现状）/ `lowestOnly`（只画剩余最低的那个 provider 段）。
- 无段时保留占位 logo。

### 5.3 悬浮 HUD

行按 `floatingProviders ∩ presentProviders`，逻辑与菜单栏一致。

### 5.4 设置

- 「账号」组：按 `Provider.allCases` 生成一行 toggle，副标题为 vendor 与发现到的账号数；未发现账号的 provider 置灰。
- 「ccpm Profiles」组：统一列表（替换 Codex / Claude 两个组），每行 provider tile、profile 名、身份、auth、当前主窗百分比；Ollama 主账号在「账号」组显示本机密钥对应的账号与计划（2026-09-05 修订：无 Cookie 入口）。
- 「其他 Codex 账号」组不变。
- 「菜单栏」组：provider toggle 列表 + 显示模式 picker + 主副窗 picker。
- 「悬浮窗」组：provider toggle 列表。

### 5.5 统计窗口

- 侧栏服务过滤：All + 每个 `presentProviders`。
- KPI：总 tokens 不变；总花费只累计 `supportsCost` provider；被过滤到单个不计费 provider 时隐藏花费 KPI 与 delta。
- 当前额度圆环：每个可见 provider 一对（主窗 / 副窗），标签用 `kind.shortLabel`。
- Timeline：按账号分区，标题来自 `identity`。
- Breakdown / 按模型：`app` 列改为 provider，增加 account 列（默认隐藏，多账号时显示）。

### 5.6 引导

「检测账号」步骤按 provider 列出发现结果（tile、来源路径、身份），toggle 写 `enabledProviders`。

### 5.7 视觉

- 新增 logo：`kimi.svg`、`glm.svg`、`ollama.svg`（取自 CodexBar，MIT，README 致谢已有）。
- 识别色：Kimi `#FE603C`、GLM `#E85A6A`、Ollama 中性灰 `#888888`；仅用于 tile，额度状态色规则不变。
- 主副窗标签 Ollama 为 `MO / WK`；Kimi 主窗副标题 `RATE`，副窗 `REQUESTS`（在 `kind.shortLabel` 之外由 descriptor 给出可选说明）。

---

## 6. 验证

### 6.1 自检脚本（cc-bar 无测试 target）

`scripts/selfcheck.sh` 用 `swiftc` 编译纯逻辑文件 + `scripts/selfcheck/main.swift`，`assert` 覆盖：

- Kimi 响应 → 主副窗百分比、detail、reset。
- GLM 响应：单 token 限额、5h + 周双限额、带 MCP、5h reset 超出 5 小时被丢弃。
- Ollama HTML：新版 `$7.50 of $60 used` + 周窗；旧版 `Session usage`；登录页判定。
- ccpm keystore 三种前缀解码。
- Pace：on pace、ahead 带 runsOut、behind、不足 3% 返回 nil、monthly 反推。
- Settings 旧键迁移为 provider 集合。

### 6.2 构建

`xcodebuild -project ccbar.xcodeproj -scheme CCBar -configuration Debug build` 通过。

### 6.3 手动验收点

- 无第三方 profile 时，Popover / 菜单栏 / HUD / 统计与改造前一致。
- `ccpm add kimi-work --provider kimi` 后重启 cc-bar，Kimi 分区出现，5H 与 WK 有百分比与 requests 明细。
- 本机装过 Ollama 且 `ollama signin` 过：Ollama Cloud 卡片显示账号、计划与月度用量；未登录时卡片提示 `run ollama signin`。
- 关闭某 provider 后菜单栏、HUD、统计均不再出现该 provider，且不再请求其接口。
- 价格表变化时 v5 汇总缓存被丢弃并重扫。

### 6.4 ccpm

`go test ./...` 通过，新增用例见 §2.5。

---

## 7. 文件清单

### cc-bar 新增

- `Core/Providers/Provider.swift`、`MonitoredAccount.swift`、`AccountCatalog.swift`
- `Core/Quota/QuotaFetcher.swift`、`QuotaPace.swift`、`KimiQuotaClient.swift`、`GLMQuotaClient.swift`、`OllamaCloudQuotaClient.swift`
- `Core/Credentials/CCPMKeystore.swift`、`OllamaLocalKey.swift`（2026-09-05 修订，原 `OllamaCookieStore.swift` 已删除）
- `MenuBar/ProviderSection.swift`、`CompactAccountRow.swift`
- `Resources/Logos/kimi.svg`、`glm.svg`、`ollama.svg`
- `scripts/selfcheck.sh`、`scripts/selfcheck/main.swift`

### cc-bar 重写或大改

`Core/AppState.swift`、`Core/Quota/QuotaModels.swift`、`Core/Storage/{QuotaCache,QuotaHistoryStore,ScanCache,Settings}.swift`、`Core/Usage/*`、`Core/Credentials/CCPMProfiles.swift`、`MenuBar/{PopoverRootView,MenuBarLabel}.swift`、`Floating/FloatingContentView.swift`、`Settings/{SettingsRootView,CCPMProfilesView}.swift`、`Main/{StatsView,DesignSystem}.swift`、`Onboarding/OnboardingView.swift`、`ccbar.xcodeproj/project.pbxproj`、`docs/{产品需求,技术实现,界面布局,设计风格}.md`

### cc-bar 删除

`MenuBar/CodexAccountsSection.swift`、`MenuBar/ClaudeAccountsSection.swift`、`MenuBar/MenuBarLabelFormatter.swift`

### ccpm

`internal/config/config.go`、`cmd/add.go`、`cmd/run.go`、`cmd/env.go`、`cmd/list.go`、`internal/claude/claude.go`、对应 `_test.go`、`README.md`

## 8. 上游合并后的类型映射（2026-09-05）

本 spec 最初实现在 0.9.0 基线上（`Provider` / `MonitoredAccount` / `QuotaFetcher`）。合并 nanvon/cc-bar v1.0.53 后，上游已经有了同构的 descriptor 表、语义化 lane 和持久化协调器，移植时保留上游模型，ccpm 账号作为附加层叠上去。旧概念与现行代码的对应关系：

| 本 spec 中的概念 | 合并后的实现 |
| :--- | :--- |
| `Provider` 枚举 + `ProviderDescriptor` | `QuotaApp`（新增 `kimi` / `glm` / `ollama`）+ `QuotaProviderDescriptor`（新增 `dashboardURL` / `statusPageWebURL`） |
| `MonitoredAccount` / `AccountID` / `AccountCredential` | 主账号沿用上游 `primaryQuotaStates[QuotaApp]`；ccpm 账号为 `CCPMAccount`（`Core/Quota/CCPMAccount.swift`），`id = "<app>:ccpm:<profile>"` |
| `AccountCatalog.discover()` | `CCPMAccountCatalog.discover(primaryCodexAccountId:primaryClaudeEmail:)`，与主账号同身份的 profile 标记 `mirrorsPrimary` 复用主账号状态 |
| `QuotaSnapshot{primary, secondary, extra}` | 上游 `QuotaSnapshot{primaryLimit, secondaryLimit, auxiliaryLimits, modelLimits}`；月度 / MCP / Extra usage 用 `kind: .unknown` + 显式 `id`/`displayName` 表达 |
| `QuotaWindow.kind` | `QuotaLimit.kind`（按秒数归类）+ `QuotaLimit.laneTitle` |
| `QuotaWindow.detail` | 同名字段，Codable 可选 |
| `QuotaFetcher` | 各 provider 客户端直接产出上游快照：`KimiQuotaClient` / `GLMQuotaClient` / `OllamaCloudQuotaClient`；Codex / Claude 沿用上游客户端 |
| `AppState.monitorSnapshot(for:)` | 同名，跨主账号与 ccpm 账号取 lane 最紧张者 |
| `QuotaCache` v2 `records` | 上游 v4 payload 新增可选字段 `ccpmAccounts: [String: QuotaCacheRecord]`；ccpm 的 `statusline` 读取该字段 |
| `scripts/selfcheck.sh` | 上游 XCTest target `CCBarTests`，用例在 `CCBarTests/MultiProviderTests.swift` |
