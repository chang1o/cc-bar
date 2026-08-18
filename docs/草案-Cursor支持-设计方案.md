# 草案 · Cursor 支持（额度 + 用量统计）

> 状态：设计方案。落地后并入《产品需求》《技术实现》《界面布局》三份常驻文档，本草案移入 `历史参考/`。

## 1. 背景与目标

在 cc-bar 中新增 Cursor 支持，展示形态对齐现有 Codex / Claude：

- **Popover**：剩余额度（Total / Auto / API 百分比、计费周期与重置时间、套餐名）。
- **主窗口**：用量统计（已使用 Token、费用，按日 / 周 / 月汇总与周期对比）。

**明确不做**：近 30 天趋势图 / 用量历史折线（现有 UI 无此形态，会扩大改动面；如需后续另立需求）。

## 2. 调研结论

Cursor 官方**没有面向个人/Pro 用户的公开稳定额度 API**（仅 Enterprise 的 Admin / Analytics API，需管理员权限）。社区有两个成熟实现可供参照：

| | CodexBar | OpenUsage |
|---|---|---|
| 认证 | 网页 Cookie（`WorkosCursorSessionToken`）| api2 RPC Bearer token |
| 主接口 | `cursor.com/api/usage-summary` 等（网页 dashboard 自用）| `api2.cursor.sh` Connect RPC（逆向最深）|
| Token 刷新 | 不刷新，等 Cursor.app | 主动 OAuth 刷新，**写回 Cursor 的 SQLite** |
| 用量费用 | 事件级 JSON，含官方 `chargedCents` 实际扣费 | CSV 导出，仅本地估算价 |
| 侵入性 | 只读用户数据 | 修改用户 Cursor 数据库 |

**本地参照仓库**（两个项目均已 clone 到本机，可随时对照读源码）：

| 项目 | 本地相对路径 | 关键代码位置 |
|---|---|---|
| CodexBar | `../CodexBar` | `Sources/CodexBarCore/Providers/Cursor/`：`CursorStatusProbe.swift`（网页接口 + 映射）、`CursorAppAuth.swift`（读 `state.vscdb`）、`CursorUsageEventsFetcher.swift`（事件分页 + `chargedCents`） |
| OpenUsage | `../openusage` | `Sources/OpenUsage/Providers/Cursor/`：`CursorAuthStore.swift`（读库 + 刷新决策）、`CursorUsageClient.swift`（接口与 OAuth 刷新）、`CursorProvider.swift`（拉取编排） |

实现时**优先参考上述本地源码**（必要时直接读代码），文档只记录决策与映射，不重复贴实现细节。另见 `历史参考/外部项目分析/` 下已归档的 codexbar 开发笔记，可作背景阅读，不约束本方案。

**组合决策**（本方案采用）：

1. **接口走网页 Cookie 路线**（CodexBar 思路）：`cursor.com` 的 dashboard 自用接口，比 `api2.cursor.sh` 逆向 RPC 稳定，且是 Cursor 网页每天在跑的路径。
2. **Token 主动刷新**（OpenUsage 思路）：同时读 `accessToken` 与 `refreshToken`，过期前自动 OAuth 刷新——但**新 token 只写 cc-bar 自己的 Keychain，绝不写回 Cursor 的 SQLite**，避免侵入用户正在使用的数据。
3. **用量费用带官方扣费口径**（CodexBar 思路）：用 `get-filtered-usage-events` 的事件级 `chargedCents`（计划实际扣款），而非本地按标价估算。

## 3. 数据源与映射

### 3.1 额度：`GET https://cursor.com/api/usage-summary`

Cookie 认证，`Accept: application/json`。返回 JSON：

| 字段 | 含义 | 单位 |
|---|---|---|
| `billingCycleStart` / `billingCycleEnd` | 计费周期起止 | ISO8601 |
| `membershipType` | `pro` / `team` / `ultra` / `enterprise` / `free` 等 | — |
| `individualUsage.plan.used` / `.limit` / `.remaining` | 套餐内用量 | 美分 |
| `individualUsage.plan.autoPercentUsed` / `.apiPercentUsed` / `.totalPercentUsed` | 三类百分比 | 已是百分数（0~100） |
| `individualUsage.plan.breakdown.included / bonus / total` | 套餐内 / 赠送 / 总计 | 美分 |
| `individualUsage.onDemand.used / limit / remaining` | 超额按量费用 | 美分 |
| `individualUsage.overall` | Enterprise / 团队成员个人上限 | 美分 |
| `teamUsage.onDemand` / `teamUsage.pooled` | 团队共享池 | 美分 |
| `isUnlimited` | 是否无限额度 | Bool |

**→ `QuotaSnapshot` 映射**：

| QuotaSnapshot 字段 | 来源 |
|---|---|
| `primaryLimit` | `totalPercentUsed` → `QuotaLimit.standard(kind: .unknown, window:)`，`window.resetsAt = billingCycleEnd`，`window.windowSeconds` 取周期秒数 |
| `secondaryLimit` | `autoPercentUsed`（有值才填，None 时省略） |
| `planType` | `membershipType`（映射为可读套餐名：Pro / Pro+ / Ultra / Team / Enterprise 等） |
| `fetchedAt` | 拉取时间 |

说明：月度计费窗口不属于现有 `QuotaLimitKind` 的 `fiveHour` / `weekly`，按 `.unknown` 处理；`QuotaWindow` 的 `usedPercent / resetsAt / windowSeconds` 与 Cursor 字段天然一一对应。

### 3.2 用量：`POST https://cursor.com/api/dashboard/get-filtered-usage-events`

Cookie 认证 + **`Origin: https://cursor.com` 头**（该 POST 端点有 CSRF 校验）。请求体 `{page, pageSize, startDate, endDate}`，时间戳为毫秒字符串，分页每页 1000 条、上限 200 页（共 20 万事件），需做页边界去重（无稳定事件 ID，按相邻页首尾精确匹配）。

每条事件关键字段：

| 字段 | 含义 |
|---|---|
| `timestamp` | 事件时间（毫秒，字符串） |
| `model` | 模型名（`auto`、`composer-*`、具体模型名等） |
| `tokenUsage.inputTokens / outputTokens / cacheWriteTokens / cacheReadTokens` | Token 明细 |
| `tokenUsage.totalCents` | 官方标价费用（美分） |
| `chargedCents` | **计划实际扣费**（美分），`nil` 时视为缺口径 |
| `requestsCosts` / `usageBasedCosts` / `isTokenBasedCall` / `owningUser` / `owningTeam` | 辅助信息 |

**→ `UsageBucket` 映射**（每条事件一条）:

| UsageBucket 字段 | 来源 |
|---|---|
| `app` | `.cursor` |
| `model` | `event.model`（缺失用 `"unknown"`） |
| `speed` | `.standard`（Cursor 无 speed 概念，避免 `unknown` 的"未计价"语义） |
| `day` | `startOfDay(timestamp)` |
| `inputTokens / outputTokens / cacheReadTokens / cacheCreationTokens` | `tokenUsage` 对应字段 |
| `costUSD` | `chargedCents / 100`（官方扣费口径） |
| `requestCount` | 1 |

聚合逻辑复用现有 `UsageAggregator`；拉取结果经 `aggregator.ingest(...)` 进入同一套 rollup 持久化链路，与本地扫描数据同代落盘。

## 4. 认证与安全设计

### 4.1 读取本地登录态

Cursor.app 的登录态存于 VS Code 风格全局库：

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

`ItemTable` 表按 key 取：

- `cursorAuth/accessToken`（JWT，约 1 小时有效）
- `cursorAuth/refreshToken`（OAuth 刷新用）

**读取方式**：复用 `OpencodeScanner` 已有的 `import SQLite3` 只读模式——`SQLITE_OPEN_READONLY` 打开，处理 WAL 侧边文件（`-wal` / `-shm`）：存在侧边文件时正常只读；空闲主库无侧边文件时用 `?immutable=1` URI 打开，避免在 Cursor 目录重建文件。

### 4.2 JWT 解析与 Cookie 构造

复用现有 `Core/Credentials/JWT.swift` 解析 payload：

- `sub`（形如 `user|<id>`，取 `|` 后部分）→ userID
- `exp` → 判断是否需刷新（剩余 < 5 分钟即刷新，留缓冲）

Cookie 构造（与 Cursor 网页登录态同格式）：

```
WorkosCursorSessionToken = <userID>%3A%3A<accessToken>
```

### 4.3 主动刷新（只写自家 Keychain）

`POST https://api2.cursor.sh/oauth/token`，body：

```json
{ "grant_type": "refresh_token", "client_id": "<逆向常量>", "refresh_token": "<refreshToken>" }
```

- 响应含 `access_token`，刷新后重新构造 cookie 继续本次请求。
- `shouldLogout: true` 或 400/401 → 会话失效，提示用户到 Cursor 重新登录。
- **新 token 仅写入 cc-bar 自己的 Keychain**（复用 `ImportedCodexStore` 的 `SecItem` 模式，service 如 `com.cc-bar.cursor`），不写回 `state.vscdb`。
- `client_id` 是逆向常量，可能随 Cursor 变更；配置集中一处便于维护。

### 4.4 安全边界

- 凭据只发给 `cursor.com` / `api2.cursor.sh`，仅 HTTPS。
- 不把 token / cookie 写入日志或 `UserDefaults`。
- 网络失败保留已有快照，不清空可展示数据。
- 429 走现有退避策略，不绕过限流。

## 5. 架构改动清单

### 新增文件

| 文件 | 职责 |
|---|---|
| `Core/Credentials/CursorAuth.swift` | 读 `state.vscdb`、JWT 解析、cookie 构造、OAuth 刷新（写 Keychain） |
| `Core/Quota/CursorQuotaClient.swift` | `usage-summary` → `QuotaSnapshot`，错误映射为 `QuotaError` |
| `Core/Usage/CursorUsageFetcher.swift` | `get-filtered-usage-events` 分页拉取 + 去重 → `[UsageBucket]` |
| 资源 | Cursor 图标（`logoName: "cursor"`）、识别色（见 §7 设计） |

### 修改文件

| 文件 | 改动 |
|---|---|
| `Core/Quota/QuotaModels.swift` | `QuotaApp` 加 `.cursor`；`QuotaProviderDescriptor.primaryProviders` 插入 Claude 之后（保持 Codex 最前） |
| `Core/Usage/UsageModels.swift` | `UsageApp` 加 `.cursor` |
| `Core/Quota/QuotaRefreshPlan.swift` | 加 `refreshCursor` 开关 |
| `Core/AppState.swift` | `primaryQuotaStates` / `quotaCache` 已按 `QuotaApp` 索引，自动支持；新增 `loadCursorQuota()` 并挂入 `refreshQuotas` |
| `Core/Usage/UsageService.swift` | 增加 Cursor 远程数据的拉取入口与调度（结果 ingest 进现有 aggregator） |
| `Core/L10n.swift` | 双语词条：Cursor、套餐、计费周期、剩余额度等 |
| UI 各层 | Popover / 主窗口 / 悬浮窗 / 设置页均按 `primaryProviders` 与 `QuotaApp.allCases` 遍历，新增 provider 自动出现，仅需确认顺序与空态 |

Settings 侧无需扩平行字段：`providerDisplaySettings` 已统一按 `QuotaApp` 索引，仅补充 `showCursor` 语义入口。

## 6. 口径说明

- **远程账单位**：Cursor 的额度与用量来自远端账户，覆盖该账号**所有设备**；与 Codex / Claude 的"本机扫描会话日志"是不同来源，UI 上在费用/来源处需能区分。
- **费用口径**：额度侧 `plan` / `onDemand` 是美分；用量侧以 `chargedCents`（官方实际扣费）为准；`tokenUsage.totalCents`（官方标价）仅作参考，不混用。
- **on-demand 位置**：超额费用属于"费用"范畴，随用量统计在**主窗口**体现；Popover 只展示额度百分比与周期。

## 7. 风险与边界

| 风险 | 说明 | 缓解 |
|---|---|---|
| 非官方接口变更 | `usage-summary` / `get-filtered-usage-events` / `oauth/token` 均无稳定性承诺 | 失败保留快照；接口字段集中解析；文档与代码同步跟进 |
| 20 万事件 / 次上限 | 单次拉取最多 200 页 × 1000 条 | 达上限显式报错不发布半截数据；按需缩小窗口 |
| 逆向 `client_id` 变更 | OAuth 刷新常量可能失效 | 集中配置；失效退化为只读模式并提示 |
| Cursor 未安装 / 未登录 | 读不到 `state.vscdb` 或 token 过期 | 显示空态 / 引导提示，不清空快照 |
| 刷新不同步回 Cursor | cc-bar 刷新后 Cursor.app 不知情 | 不涉及：cc-bar 不写 Cursor 库，无同步问题；若 Cursor 侧先刷新导致 refresh token 失效，提示重新登录 |

## 8. 实施步骤

1. **认证层**：`CursorAuth`（读库 → 解析 → 刷新 → 缓存到 Keychain）。
2. **额度**：`QuotaApp.cursor` + `CursorQuotaClient` + `AppState` 调度 + `QuotaCache` 缓存。
3. **用量**：`UsageApp.cursor` + `CursorUsageFetcher` + 聚合接入。
4. **UI 收尾**：图标、识别色、L10n、设置开关、Popover / 主窗口空态与错误态。
5. **文档同步**：并入《产品需求》《技术实现》《界面布局》。

## 9. 验收标准

- Popover 显示 Cursor 剩余额度（Total 百分比 + 计费周期重置时间 + 套餐名），与 Cursor 网页 Spending dashboard 一致。
- 主窗口统计页显示 Cursor 按日 / 周 / 月汇总的 Token 与费用，费用与 dashboard 账单口径一致（官方扣费）。
- Cursor 排在 Claude 之后、Codex 之前（Codex 永远最前）。
- Cursor 未登录 / 未安装时显示空态或错误提示，不清空已有快照。
- 429 遵守现有退避策略；失败不清空可展示数据。
- 不写回 Cursor 的 `state.vscdb`，不动用户正在使用的数据。