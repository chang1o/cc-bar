import Foundation

// MARK: - UpdateChecker（GitHub 发布检查）
//
// 数据源: GitHub Releases API `GET /repos/{owner}/{repo}/releases/latest`(公开仓库,匿名访问)。
// 用途: 设置页「检查更新」手动检查 + 可选的启动时自动检查(见 SettingsStore.autoCheckForUpdates)。
// 版本号来自 release tag(`vX.Y.Z`),与 project.pbxproj 的 MARKETING_VERSION / Info.plist 的
// CFBundleShortVersionString 对应。匿名访问受 60 次/小时/IP 限制,因此只做按需检查,不做轮询。
//
// 只负责告知与跳转下载页(Release page),不做自动下载/安装——工程是 ad-hoc 签名、
// 未公证,自动替换会被 Gatekeeper 拦截,且覆盖 /Applications 中的安装有风险。
//
// 见 docs/技术实现.md "更新检查" 一节。

enum UpdateChecker {
    /// 仓库大小写与 README 中徽章一致;如日后换仓库只需改这两处。
    static let repoOwner = "nanvon"
    static let repoName = "cc-bar"

    /// 由 GitHub 重定向到最新 release 的下载页。
    static let releasePageURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!

    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!

    struct ReleaseInfo: Equatable, Sendable {
        /// tag 原名,如 `v1.0.2`。
        let tag: String
        let htmlURL: URL?
    }

    /// 拉取最新 release 信息。任何网络 / 解码错误都抛出,调用方负责状态展示。
    static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        struct Payload: Decodable {
            let tagName: String?
            let htmlURL: URL?
            private enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return ReleaseInfo(tag: payload.tagName ?? "", htmlURL: payload.htmlURL)
    }

    /// 判断 tag(`vX.Y.Z`)是否比当前版本新。任一格式无法解析时按「不更新」处理,避免误报。
    static func isNewer(tag: String, than currentVersion: String) -> Bool {
        guard let new = numericComponents(of: tag), let cur = numericComponents(of: currentVersion) else {
            return false
        }
        let count = max(new.count, cur.count)
        for i in 0..<count {
            let a = i < new.count ? new[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 把版本字符串解析为数字分量:`v1.0.2` / `1.0` → [1, 0, 2]。
    /// 前缀 `v` 忽略,遇到非纯数字段(如 `-beta.1` 后缀)截断后续分量;首段非数字返回 nil。
    static func numericComponents(of version: String) -> [Int]? {
        var clean = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("v") || clean.hasPrefix("V") {
            clean.removeFirst()
        }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let firstNumber = Int(first) else { return nil }

        var result = [firstNumber]
        for part in parts.dropFirst() {
            guard let number = Int(part) else { break }
            result.append(number)
        }
        return result
    }
}
