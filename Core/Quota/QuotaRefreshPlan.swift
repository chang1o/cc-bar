import Foundation

/// 一轮额度刷新计划的声明式描述（草案-性能与功耗等价优化方案 §4.1）。
/// 由当前设置与账号可见性一次性构造，供 `AppState.refreshQuotas` 裁剪链路，
/// 也便于测试矩阵直接验证各开关组合，不把开关判断散落到各 Client。
struct QuotaRefreshPlan: Equatable, Sendable {
    var refreshCodex: Bool
    var refreshClaude: Bool
    var refreshAntigravity: Bool
    var refreshCursor: Bool
    var refreshCommandCode: Bool
    /// 有可见导入 Codex 账号时需要调度导入刷新（是否真正刷新仍按各账号
    /// 自身 `visibleInPopover` 过滤；此处只表达"存在可见项"）。
    var refreshImported: Bool
    /// 主 Codex 启用时，导入账号与主账号同身份可镜像（同一身份只请求一次额度）；
    /// 主 Codex 关闭时即使内存还留有旧身份，可见导入账号也必须用自己的
    /// Keychain 凭据独立刷新，不能复制可能过期的主账号快照。
    var canMirrorPrimary: Bool

    static func make(
        showCodex: Bool,
        showClaude: Bool,
        showAntigravity: Bool = false,
        showCursor: Bool,
        showCommandCode: Bool = false,
        hasVisibleImported: Bool
    ) -> QuotaRefreshPlan {
        QuotaRefreshPlan(
            refreshCodex: showCodex,
            refreshClaude: showClaude,
            refreshAntigravity: showAntigravity,
            refreshCursor: showCursor,
            refreshCommandCode: showCommandCode,
            refreshImported: hasVisibleImported,
            canMirrorPrimary: showCodex
        )
    }
}
