# 草案 · Command Code GOAT 订阅额度支持

> 状态：产品范围与第一版交互已收敛，本文档作为后续开发基线。当前只完成设计与本地源码 / 公开资料调研，尚未实施代码，也尚未使用本机真实 Command Code 凭据完成接口端到端验证。实现完成并验收后，再把最终行为并入 `产品需求.md`、`技术实现.md`、`界面布局.md` 与 `设计风格.md`，并归档本草案。
>
> 核心边界：**Command Code 在本功能中是“订阅额度 Provider”，只进入「设置 → 账号」和 Popover；它不是新的本地用量统计服务，不进入主窗口。**主窗口继续按 Codex / Claude Code / Cursor / Pi / OpenCode 的真实数据源统计对话 Token 与 API 等值预估费用。

## 1. 结论与产品定位

### 1.1 两条数据链必须严格区分

| 数据链 | 回答的问题 | 数据来源 | 展示位置 | 统计口径 |
|---|---|---|---|---|
| Command Code 订阅额度 | 这个 Command Code 账号的 GOAT 套餐还剩多少额度、何时重置 | Command Code 账户接口 | Popover | 账号级 5 小时 / 周 / 月订阅 credits |
| Agent 对话用量 | 本机各 Agent 对话用了多少 Token、按模型 API 价格约等于多少钱 | Codex / Claude / Pi JSONL、OpenCode SQLite、Cursor 远端事件 | 主窗口 Statistics | Agent 工具级本地或既有远端统计 |

两者不能互相换算、合并或回退：

- Command Code 的 5 小时 / 周 / 月 credits 是账号级订阅消耗，可能包含 Pi、OpenCode、Command Code CLI、其他设备或其他客户端产生的用量。
- 主窗口的 Token 与费用是 Agent 会话维度；其中费用是本地日志已有费用或按模型公开价格计算的 API 等值估算，不代表 Command Code 订阅实际扣减。
- Pi / OpenCode 对话中使用 `commandcode/...` 或 `command-code/...` 模型时，仍分别归属 **Pi / OpenCode 服务**；现有“按提供商”面板可继续把这些模型归为 `Command Code`，但不新增 `UsageApp.commandCode`。
- 不用订阅 credits 反推 Token，不用本机 Token 反推订阅剩余额度，也不拿 `/alpha/usage/summary` 填主窗口历史统计。

### 1.2 第一版产品范围

- **设置 → 账号**：新增 Command Code 账号行和 Provider 总开关，交互语义与 Codex / Claude Code 账号行一致。
- **Popover**：打开总开关后新增 Command Code block，显示 5H、Weekly、Monthly 三档订阅额度及重置时间。
- **凭据**：默认自动只读复用本机已有登录态；提供手动 API key 作为兜底，手动 key 只存 macOS Keychain。
- **刷新**：接入现有额度刷新调度、60 秒最小成功间隔与 429 退避；刷新失败保留同账号旧快照。
- **默认状态**：新旧用户均默认关闭 Command Code Provider。只有用户在设置中开启后才发远端额度请求。
- **排序**：设置账号行与 Popover block 均排在 Cursor 之后。

### 1.3 第一版明确不做

- 不进入菜单栏额度文字。
- 不进入桌面悬浮窗。
- 不进入主窗口 Overview / Conversations / Timeline / Cycles，也不新增“统计服务”开关。
- 不进入 Onboarding；自动检测结果在「设置 → 账号」呈现即可。
- 不展示今日 / 本周费用，`showsCost = false`。
- 不展示或合并 purchased / free / top-up credits；它们不是 GOAT 订阅窗口额度，后续如需支持应作为独立余额信息设计。
- 不调用 Command Code 的模型推理接口，不发送 prompt，不读取对话内容。
- 不实现应用内 OAuth / 浏览器登录，不读取、保存或轮换 refresh token。
- 不支持多 Command Code 账号并排展示；第一版只有一个当前账号。
- 不记录 Command Code 额度 Timeline / Cycles 历史。

## 2. 产品交互

### 2.1 设置 → 账号

新增账号行：

| 字段 | 设计 |
|---|---|
| 标题 | `Command Code` |
| 厂商副标 | `Command Code` |
| 账号 | 优先显示 `/alpha/whoami` 返回的 `login`；隐私模式开启时隐藏 |
| 套餐 | `individual-goat` 映射为 `GOAT`；未知值做安全格式化，不伪造套餐 |
| 状态 | `Connected · 已连接` / `Not detected · 未检测到` / 通用失败状态 |
| 总开关 | 默认关闭；只控制 Command Code 的 Popover block 与额度轮询 |
| 凭据入口 | 行内 `key` / `ellipsis` 小按钮，打开凭据来源设置，不把 key 直接铺在账号列表中 |

Provider 总开关语义：

```text
关闭 → Popover 不显示，不发 Command Code 额度请求
开启 → Popover 显示，并加入额度刷新计划
```

它没有菜单栏、悬浮窗、统计服务三个子开关。实现时不能因为 `QuotaProviderDescriptor.primaryProviders` 当前被多个界面共用，就让 Command Code 自动出现在这些设置组中。

### 2.2 凭据来源设置

第一版采用两档来源：

1. **Automatic · 自动（推荐）**
   - 只读扫描本机 Command Code / Pi / OpenCode 登录态。
   - 显示当前命中的来源，例如 `Using Pi login · 正在使用 Pi 登录态`。
   - 不把自动读取到的 token 复制进 CCBar Keychain。
2. **Manual API key · 手动 API key**
   - 使用 `SecureField` 输入。
   - 保存后只写 macOS Keychain，不写 UserDefaults、JSON、日志或额度缓存。
   - 支持 Replace / Remove；移除后回到未配置状态，不自动改写 Pi / OpenCode 文件。

第一版不提供“登录 Command Code”按钮。只有 Command Code 提供稳定、面向第三方 App 的 OAuth 契约后，才单独评估应用内登录。

### 2.3 Popover block

Popover 复用 `ServiceBlockView` 的主要额度 + 紧凑额度行结构：

| 位置 | 稳定 ID | 标签 | 数据 |
|---|---|---|---|
| `primaryLimit` | `command-code-five-hour` | `5HOUR` | 5 小时窗口 |
| `secondaryLimit` | `command-code-weekly` | `WEEKLY` | 7 天滚动窗口 |
| `auxiliaryLimits[0]` | `command-code-monthly` | `MONTHLY` | 当前订阅计费周期 |

展示规则：

- 百分比统一显示**剩余**；进度条和颜色继续走现有 `remainingPercent` / `statusColor`。
- 5H / Weekly 的 reset 使用服务端 `resetAt`，它们从第一次请求开始滚动，不按自然整点、自然周计算。
- Monthly 的 reset 使用 `currentPeriodEnd`。
- 副标题显示账号 login + `GOAT`；隐私模式下只显示 `GOAT`，未知套餐回退 `Command Code`。
- 不显示 today / week cost 行，不显示 purchased / free credits，不显示服务状态圆点。
- 部分窗口有效时只展示有效窗口；字段缺失绝不能显示成 `0% 已用` 或 `100% 剩余`。

## 3. 凭据方案

### 3.1 推荐策略

采用“**自动只读为主，手动 Keychain 为兜底，不做应用内登录**”的混合方案。

原因：

- 用户已经在 Pi / OpenCode 登录，自动读取无需重复配置。
- 只读取 access / api key，不碰 refresh token，不会争抢或破坏宿主 Agent 的登录态。
- 手动 key 覆盖未安装 Pi / OpenCode、登录文件结构变化、用户希望使用另一个账号等场景。
- 当前没有可依赖的第三方 OAuth 契约；自建网页登录流程会扩大安全和兼容风险。

### 3.2 自动发现顺序

按下面顺序构造候选，不扫描备份文件，不做模糊目录搜索：

1. `~/.commandcode/auth.json`
2. `~/.pi/agent/auth.json` 的 `commandcode` 项
3. `~/.local/share/opencode/auth.json` 的 `command-code` 项
4. `COMMANDCODE_API_KEY` / `COMMAND_CODE_API_KEY` 环境变量（仅兜底；从 Finder 启动通常拿不到终端临时变量）

兼容的 token 字段只做白名单解析：

- `type == "oauth"` 时读取非空 `access`。
- `type == "api"` 时读取非空 `key`。
- 官方独立文件可兼容顶层 `apiKey`。
- 不读取 `refresh`，不依据本地 `expires` 主动续期；每轮刷新前重新读取当前来源。
- key 去除首尾空白后必须非空、无控制字符，并设置合理长度上限。

如果多个候选同时存在：

- 本进程优先复用最近一次成功的来源，减少每轮跨来源探测。
- 没有成功记录时按固定顺序尝试。
- 只有 401 / 403 这类凭据拒绝才尝试下一个自动候选。
- 网络失败、超时、429、5xx 或响应 schema 变化时不切换凭据，避免一次服务端故障被误判为账号切换并放大请求量。
- 新候选成功且 `orgId` 不同时视为账号切换，先隔离旧缓存再展示新数据。

### 3.3 手动 key 存储

- Keychain service 建议：`com.nanvon.ccbar.command-code`。
- account 建议：`primary`。
- UserDefaults 只保存来源枚举（automatic / manual），不保存 key、token 指纹或响应正文。
- 手动 key 保存后触发一次用户发起的额度刷新；失败时显示固定错误分类，不能把服务端正文直接展示或落日志。
- 删除手动 key 使用 Keychain 删除 API，不影响自动来源文件。

### 3.4 账号身份与缓存绑定

- `/alpha/whoami` 有 `org.id` 时，缓存 `accountID` 使用 `orgId`。
- 没有 `orgId` 时，使用 token 的完整 SHA-256 摘要作为仅内部使用的账号键；不展示、不记录。
- `quota-cache.json` 只保存额度快照、来源类型、更新时间和账号键，不保存 access token。
- 启动时可读入缓存，但只有完成本地凭据解析且缓存 `accountID` 与当前账号一致后才公开展示，避免闪出上一个账号的额度。

## 4. 远端接口与稳定性等级

### 4.1 接口链路

请求统一使用：

```http
Accept: application/json
Authorization: Bearer <access-or-api-key>
```

第一版只调用：

```text
GET https://api.commandcode.ai/alpha/whoami
  ↓ orgId
GET https://api.commandcode.ai/alpha/billing/credits?orgId=<orgId>
GET https://api.commandcode.ai/alpha/billing/subscriptions?orgId=<orgId>
```

- `whoami` 先执行，用于验证凭据、取得 login 与 orgId。
- `credits` 与 `subscriptions` 在 `whoami` 成功后并发执行。
- 整轮建议使用 15 秒总超时，并响应 Task cancellation。
- orgId 缺失时省略 query 参数，不能拼出 `orgId=`。

第一版**不调用** `/alpha/usage/summary`：

- Popover 需要的 5H / Weekly 来自 `billing/credits.windowLimits`。
- Monthly 剩余额度来自 `billing/credits.credits.monthlyCredits`，周期结束来自 subscription。
- summary 的 `totalCost / totalCount / totalTokens` 是账号级汇总，不等于本机 Agent 对话统计；引入它反而容易把两条产品链混在一起。

### 4.2 响应字段

`billing/credits` 关注：

```json
{
  "credits": {
    "monthlyCredits": 0,
    "purchasedCredits": 0,
    "freeCredits": 0
  },
  "windowLimits": {
    "fiveHour": { "used": 0, "cap": 14, "resetAt": 0 },
    "weekly": { "used": 0, "cap": 35, "resetAt": 0 }
  }
}
```

`billing/subscriptions` 关注：

```json
{
  "data": {
    "planId": "individual-goat",
    "status": "active",
    "currentPeriodStart": "<ISO8601>",
    "currentPeriodEnd": "<ISO8601>"
  }
}
```

`whoami` 关注 `org.login` / `user.userName` / `user.name`、`org.id` 和可选 key name。解析器必须容忍无关字段增加。

### 4.3 稳定性定级

- Command Code 官方文档明确 GOAT 为 5 小时 14 credits、每周 35 credits、每月 70 credits，并说明 `/usage` 能显示实时窗口与 reset。
- 官方 Provider API 文档公开的是模型推理接口，不包含稳定的第三方订阅额度 API。
- 这里使用的 `/alpha/*` 端点与 Command Code CLI `/usage`、社区 `pi-commandcode-provider` 的额度命令一致，但仍应标记为**兼容性 / best-effort 接入**。

因此：

- 解析 schema 变化必须与真实 0 值区分。
- 技术错误只记录固定分类 + HTTP status，不记录 Authorization、key、token、完整响应正文。
- 端点失效不能影响 Codex / Claude / Cursor 或本地用量扫描。
- 后续如果 Command Code 提供正式 quota API，只替换 Client，保持 `QuotaSnapshot` 和 UI 契约不变。

## 5. 数据映射

### 5.1 5 小时与周窗口

对每个窗口：

```text
usedPercent = cap > 0 ? clamp(used / cap × 100, 0...100) : nil
remainingPercent = 100 - usedPercent
```

| 服务端字段 | `QuotaLimit` |
|---|---|
| `fiveHour.used / cap` | `primaryLimit.window.usedPercent` |
| `fiveHour.resetAt` | `primaryLimit.window.resetsAt` |
| 固定窗口 | `kind = .fiveHour`, `windowSeconds = 18_000` |
| `weekly.used / cap` | `secondaryLimit.window.usedPercent` |
| `weekly.resetAt` | `secondaryLimit.window.resetsAt` |
| 固定窗口 | `kind = .weekly`, `windowSeconds = 604_800` |

规则：

- `used`、`cap` 必须是有限且非负数，`cap > 0` 才生成百分比窗口。
- `resetAt` 同时兼容 Unix 秒、Unix 毫秒和 ISO8601 字符串；无法解析时额度仍可显示，但 reset 为 `nil`。
- 服务端动态 `cap` 是 5H / Weekly 的权威值，不在代码里硬编码 14 / 35 做计算。

### 5.2 月度窗口

GOAT 月度总额来自官方套餐目录，当前可靠映射：

```text
individual-goat → GOAT → monthlyCap = 70
```

计算：

```text
monthlyRemaining = credits.monthlyCredits
monthlyUsed = clamp(monthlyCap - monthlyRemaining, 0...monthlyCap)
monthlyUsedPercent = monthlyUsed / monthlyCap × 100
monthlyResetAt = subscription.currentPeriodEnd
```

规则：

- Monthly 只使用 `monthlyCredits`，不把 `purchasedCredits` / `freeCredits` 加入订阅池。
- `planId` 未知或没有可靠月总额时，不伪造 monthly percentage；只展示 5H / Weekly。
- `currentPeriodEnd` 缺失时仍可显示月度百分比，但 reset 显示 `—`。
- 以后扩展其他套餐时，套餐目录应集中维护并附官方来源，不把总额散落在解析器或 View 中。

### 5.3 `QuotaSnapshot`

```swift
QuotaSnapshot(
    app: .commandCode,
    primaryLimit: fiveHour,
    secondaryLimit: weekly,
    auxiliaryLimits: monthly.map { [$0] } ?? [],
    modelLimits: [],
    planType: formattedPlan,
    fetchedAt: now
)
```

- `showsCost = false`。
- `usageApp = nil`。
- `isUnlimited = nil`。
- 至少成功解析一个额度窗口才发布新快照。
- 部分成功时发布已知窗口，并显式记录缺失 section 供诊断；不能补 0。

## 6. 状态、错误与刷新策略

### 6.1 状态分类

| 状态 | 触发 | 设置 | Popover |
|---|---|---|---|
| 未检测到 | 自动与手动来源都没有合法 key | `Not detected`，总开关不可用 | 不显示 block |
| 已检测、未开启 | 有凭据但总开关关闭 | `Connected`，开关关闭 | 不显示，不请求远端 |
| 正常 | 至少一个额度窗口成功 | `Connected` | 展示成功窗口 |
| 凭据失效 | 所有候选均 401 / 403 | 固定失败提示 | 保留同账号旧快照 + `刷新失败` |
| 限流 | 429 | 不改账号态 | 保留旧快照，进入 10 分钟退避 |
| 服务失败 | timeout / network / 5xx | 不改账号态 | 保留旧快照 + `刷新失败` |
| 契约不可用 | 404 / envelope 变化 / 全部窗口不可解析 | 固定“暂不可用” | 不把旧值冒充最新；可显示不可用占位 |

### 6.2 与现有调度保持一致

- 周期刷新遵守用户设置的 quota interval。
- 成功请求 60 秒内不重复请求；用户手动刷新可绕过普通节流，但不能绕过 429 退避。
- 同一个 Provider 同时只允许一个 in-flight 请求。
- 网络失败保留已有同账号快照，不清空。
- 开关从关闭切为开启时触发一次 `.userInitiated` 刷新。
- 关闭开关后停止后续远端请求，但可保留缓存，重新开启时先显示同账号旧快照再刷新。

## 7. 代码结构建议

### 7.1 新增模块

```text
Core/Credentials/CommandCodeAuth.swift
Core/Quota/CommandCodeQuotaClient.swift
```

建议类型：

```swift
struct CommandCodeAuthSession {
    let accessToken: String
    let source: CommandCodeCredentialSource
    let credentialFingerprint: String
}

enum CommandCodeCredentialSource {
    case commandCodeFile
    case pi
    case openCode
    case environment
    case keychain
}

struct CommandCodeAccount {
    let login: String?
    let orgID: String?
    let planType: String?
    let credentialSource: CommandCodeCredentialSource
}
```

Client 只负责 HTTP、宽容解析与 `QuotaSnapshot` 映射；凭据发现、Keychain 和来源优先级放在 `CommandCodeAuth`，不要把文件系统逻辑塞进 Client。

### 7.2 Provider 能力边界

当前 `QuotaProviderDescriptor.primaryProviders` 同时驱动 Popover、菜单栏、悬浮窗和设置循环。直接追加 `.commandCode` 会意外扩散到第一版明确不做的界面。

实现前先给 descriptor 增加最小能力声明或派生集合，例如：

```swift
let supportsMenuBar: Bool
let supportsFloatingHUD: Bool
let recordsQuotaHistory: Bool
let recordsQuotaCycles: Bool

static var accountProviders: [QuotaProviderDescriptor]
static var popoverProviders: [QuotaProviderDescriptor]
static var menuBarProviders: [QuotaProviderDescriptor]
static var floatingProviders: [QuotaProviderDescriptor]
```

Command Code 第一版能力：

| 能力 | 值 |
|---|---:|
| Accounts | true |
| Popover | true |
| Menu Bar | false |
| Floating HUD | false |
| Stats / Conversations | false |
| Timeline / Cycles | false |
| Cost rows | false |

这个拆分必须保持 Codex / Claude / Cursor 当前行为不变，不能借接入新 Provider 做无关重构。

### 7.3 现有文件预计改动

| 文件 / 模块 | 目的 |
|---|---|
| `Core/Quota/QuotaModels.swift` | 新增 `.commandCode`、descriptor 与能力；`usageApp = nil` |
| `Core/Quota/QuotaRefreshPlan.swift` | 增加 Command Code 刷新位，保持声明式开关裁剪 |
| `Core/AppState.swift` | 账号检测、刷新、缓存绑定、错误状态 |
| `Core/Storage/Settings.swift` | 默认关闭的 Provider 设置、凭据来源偏好 |
| `Core/Storage/QuotaCache.swift` | 增加便捷访问或沿用 provider 字典；绑定 accountID |
| `Settings/SettingsRootView.swift` | 账号行、总开关、凭据来源设置 |
| `MenuBar/PopoverRootView.swift` | 新 Provider 副标题与 cost/status 分支 |
| `Main/DesignSystem.swift` / `Resources` | Command Code 识别色与 logo；仍服从额度状态色，不用品牌色表达剩余状态 |
| `ccbar.xcodeproj/project.pbxproj` | 将新增 Swift / 资源加入工程（若工程未自动同步） |
| `docs/*.md` | 实现完成后同步正式产品、技术、布局、设计文档 |

明确不改：

- `UsageApp`、`UsageService`、本地 Scanner、Conversation rollup。
- `ModelProvider.commandCode` 的现有统计归并语义。
- Cursor 远端历史用量链路。
- `QuotaHistoryStore` / `QuotaCycleStore` 的记录范围。

## 8. 安全与隐私边界

- 自动来源只读；绝不写回 Pi、OpenCode 或 Command Code 的 auth 文件。
- 只读取明确文件和明确 JSON key，不读取 `*.backup`、不遍历整个 auth 目录。
- 只使用 access / api key，不读取或使用 refresh token。
- 自动 token 不复制进 Keychain；只有用户手动输入的 key 进入 Keychain。
- 不在日志、错误、诊断、缓存、崩溃信息中输出 token、token 片段、Authorization 或响应正文。
- 请求只发往 `https://api.commandcode.ai`；不允许服务端响应或配置把请求重定向到任意第三方 host。
- URLSession 应禁用或严格校验跨 host 重定向，避免 Authorization 被带到其他域名。
- 本功能会把 access / api key 作为 Bearer 凭据发送给 Command Code 官方 API，因此 UI 文案不能写成“凭据不会发送到任何地方”；准确表述应为“只读使用本机登录态，并仅向 Command Code 查询额度”。

## 9. 测试与验收

### 9.1 单元测试

- Pi / OpenCode / 独立 auth 文件的合法、缺失、损坏、错误 type、空 key、控制字符解析。
- 自动候选优先级与最近成功来源复用。
- 401 / 403 才 fallback；429 / network / schema error 不 fallback。
- whoami / credits / subscription 的完整、部分、字段新增、字段缺失、错误类型响应。
- resetAt 秒 / 毫秒 / ISO8601 解析。
- 5H / Weekly `used / cap` 百分比与 clamp。
- GOAT monthly 剩余、已用、重置时间映射；purchased / free 不混入。
- 未知 planId 不生成伪 monthly。
- 缓存 accountID 匹配 / 不匹配，账号切换不串额度。
- 429 退避、60 秒节流、in-flight 去重与失败保留旧快照。
- Provider 能力列表：Command Code 只出现在 Accounts / Popover，不出现在菜单栏、Floating、Stats、Timeline、Cycles。
- 缓存旧版本可解码，新增 `.commandCode` 后编码 / 解码对称。

所有凭据测试只用伪造 token fixture，不能读取开发机真实 auth。

### 9.2 真实接口验收

真实验收需要用户明确授权后，使用本机当前 Pi / OpenCode 中的 Command Code access token 做只读请求。验收至少记录脱敏结果：

- 命中的凭据来源，不记录 token。
- whoami 是否成功、orgId 是否存在（只记录存在性或脱敏值）。
- planId / status。
- 5H / Weekly 的 `used`、`cap`、resetAt 是否与 Command Code CLI `/usage` 同时刻基本一致。
- `monthlyCredits` 与 Studio / `/usage` 的剩余月额度是否一致。
- 关闭 Provider 后不再产生 Command Code 网络请求。
- Pi 与 OpenCode 凭据分别失效 / 更新时能自动恢复，且不串旧账号缓存。

### 9.3 UI 验收

- 设置中出现 Command Code 行，默认关闭；能识别自动来源并切到手动 key。
- 开启后 Popover 顺序为 Codex → Claude Code → Cursor → Command Code（只显示已启用项）。
- GOAT 显示 5H / Weekly / Monthly 三档剩余比例与正确 reset。
- 隐私模式隐藏 login，但保留套餐。
- 字段部分缺失、断网、429 时不出现伪 0 / 100，旧快照保留策略符合 §6。
- 菜单栏设置、Floating 设置、统计服务、主窗口所有视图、Onboarding 均不出现 Command Code 额度项。
- Pi / OpenCode 中使用 Command Code 模型的已有对话统计仍正常，服务归属不变，“按提供商”仍可归为 Command Code。

## 10. 开发顺序

1. 用脱敏方式完成一次真实接口验证，冻结本机实际响应 fixture。
2. 实现 `CommandCodeAuth` 与 Keychain 手动兜底，并补凭据单测。
3. 实现 `CommandCodeQuotaClient`、套餐目录、解析与映射单测。
4. 拆分 Provider 界面能力集合，先证明现有 Codex / Claude / Cursor 行为不变。
5. 接入 Settings、刷新计划、AppState、缓存与 Popover。
6. 做静态检查与 diff 审阅；需要编译时按仓库规则另行确认后运行 Debug Xcode build。
7. 使用 GOAT 账号对照 `/usage` 做真实 UI 验收。
8. 验收通过后同步正式四份文档并归档本草案。

## 11. 已明确与待验证事项

### 11.1 已明确的产品决策

- Command Code 是订阅额度 Provider，不是主窗口统计服务。
- 第一版只做设置账号开关 + Popover。
- 默认关闭，不进入菜单栏、悬浮窗、Onboarding、Timeline、Cycles。
- 自动读本地 auth 为主，Keychain 手动 key 为兜底，不做应用内登录。
- 显示 GOAT 的 5H / Weekly / Monthly；不显示 cost，不混 top-up credits。

### 11.2 实现前仍需验证的技术事实

- 当前真实 GOAT 响应中的 `planId` 是否稳定为 `individual-goat`。
- `monthlyCredits` 与官方 `/usage` 展示的月度剩余额度是否完全一致。
- `resetAt` 在真实响应中实际使用秒、毫秒还是字符串（解析器会全部兼容）。
- Pi 与 OpenCode 当前两份 access token 是否都能访问同一组 alpha 额度端点，以及是否属于同一 org。
- Command Code 品牌 logo / 识别色最终资源；它只影响品牌 tile，不影响额度状态色。

这些是契约与资源验证，不会改变本方案的产品边界。

## 12. 参考资料

- [Command Code · GOAT Plan](https://commandcode.ai/docs/plans/goat)
- [Command Code · Usage Limits](https://commandcode.ai/docs/resources/usage-limits)
- [Command Code · Provider API](https://commandcode.ai/docs/provider)
- [pi-commandcode-provider · quota.ts](https://github.com/patlux/pi-commandcode-provider/blob/main/src/quota.ts)
- [pi-commandcode-provider · quota support PR #52](https://github.com/patlux/pi-commandcode-provider/pull/52)
- [CodexBar · Command Code provider notes](https://github.com/steipete/CodexBar/blob/main/docs/command-code.md)

