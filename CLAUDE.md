# cc-bar Agent Guide

本文件同时给 Claude Code 和 Codex 使用。`AGENTS.md` 应作为指向本文件的软链接，避免两份规则不一致。

## 项目概况

cc-bar 是一个原生 macOS 菜单栏 App，用 Swift / SwiftUI 实现，用于展示 Codex、Claude Code、Kimi Code、GLM Coding Plan、Ollama Cloud 的额度、消耗节奏、刷新状态、本地用量统计和桌面悬浮窗。第三方 provider 的账号全部来自 ccpm profile（`~/.ccpm/config.json` 的 `provider` 字段），cc-bar 自身不提供填 key 的入口。

项目主体功能已开发完成，后续以新需求和迭代为主，不再按初始里程碑推进。

工程结构：

- 入口：`CCBarApp.swift`
- 全局状态：`Core/AppState.swift`（账号列表 + 按 `AccountID` 的额度状态）
- Provider 与账号模型：`Core/Providers/`（`Provider` / `ProviderDescriptor` / `MonitoredAccount` / `AccountCatalog`）
- 菜单栏：`MenuBar/`
- 主窗口：`Main/`
- 悬浮窗：`Floating/`
- 引导：`Onboarding/`
- 设置：`Settings/`
- 凭据 / 额度 / 调度 / 用量 / 存储：`Core/`
- Xcode 工程：`ccbar.xcodeproj`

## 必读文档

改动前优先阅读相关文档和现有实现。文档索引见 [docs/README.md](docs/README.md),常用入口：

- `docs/产品需求.md`：产品形态、功能范围、边界
- `docs/技术实现.md`：架构、模块、关键流程、并发与持久化
- `docs/设计风格.md`：视觉规范、颜色、字体、状态色、组件尺寸、双语词表
- `docs/界面布局.md`：菜单栏、Popover、主窗口、悬浮窗、设置、引导的逐界面尺寸与字段

历史参考(已归档)位于 `docs/历史参考/`,含 `实施里程碑.md`、`设计稿/`、`外部项目分析/`。新需求**不**受里程碑顺序约束;需要对照外部项目行为时,优先看 `外部项目分析/` 已整理的笔记。

## 协作规则

- 未经明确要求“修改、实现、修复”等，不要擅自改代码。默认先分析、定位问题、给方案和风险。
- 如果需求、边界、验收标准或影响范围不明确，并且会影响实现或引入风险，先确认。
- 对大型项目，不要主动运行 `build`、`lint`、`type-check`、`test`、`dev` 等耗时或大量输出命令。确实需要时，先说明原因并询问。
- 修改前先读现有实现、项目规则、公共组件、公共规范和相关文档。
- 涉及功能、交互、数据结构、接口或配置行为变更时，必须同步更新相关文档；若判断无需更新文档，需要在回复里说明原因。
- 遵循当前项目风格，不做无关重构。
- 只改和当前任务直接相关的文件。不要顺手整理无关代码、格式或项目结构。
- 工作区可能已有用户改动。不要回滚、覆盖或清理非本次任务产生的改动。

## 实现约束

- UI 优先使用 SwiftUI / AppKit 系统默认控件和 macOS 原生风格。
- 视觉规则以 `docs/设计风格.md` 为准：
  - 识别色统一通过 `Provider.accent` 取：Codex 石墨灰、Claude Code 桃橙、Kimi 橘红、GLM 玫红、Ollama 中性灰；识别色仅用于 tile / logo / 图表等品牌识别，不再用于额度状态着色。
  - 额度状态色按剩余比例分 4 档交通灯（统一走 `statusColor`）：剩余 `>50%` 绿、`20%~50%` 黄、`<20%` 橙、`=0` 红。
  - 数字使用 `.monospacedDigit()`。
  - 图标优先使用 SF Symbols。
- 不自造大面积背景、玻璃阴影、Web 风格控件或无关装饰。
- provider 显示顺序固定为 `Provider.allCases`（Codex → Claude Code → Kimi Code → GLM → Ollama Cloud），菜单栏和 Popover 中 Codex 永远排在 Claude 前。
- 新增 provider 只改 `ProviderDescriptor.all`、`AccountCatalog` 的 ccpm 映射和一个额度客户端；UI 层不允许再按 provider 写硬编码分支，一律遍历 `appState.accounts` / `presentProviders`。
- 不做浏览器 Cookie 自动导入；Ollama Cloud 只接受用户在设置里手动粘贴的 Cookie 头。
- 网络请求失败时保留已有快照，不要清空可展示数据。
- 429 后必须遵守现有退避策略，不要为了手动刷新绕过限流。

## 常用验证方式

按任务风险选择最小验证手段：

- 纯逻辑改动（额度解析器 / `QuotaPace` / ccpm keystore 解码）：跑 `scripts/selfcheck.sh`，用 `swiftc` 单独编译，不需要 Xcode。
- 小范围 UI 改动：先做静态检查和代码审阅。
- 需要编译确认时，先说明原因，再询问是否运行 Xcode 构建。
- 需要手动验收时，说明在 Xcode 中打开 `ccbar.xcodeproj` 并运行 App，按本次需求的验收点检查。

不要为了验证一个小改动主动跑完整构建、完整测试或启动开发服务，除非用户明确要求。
