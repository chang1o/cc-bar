import Foundation

/// 从指定字节偏移开始按行读取一个文件，返回行数组和新的偏移量。
/// 简单实现：一次性读入 `offset` 之后的字节，按 `\n` 切分。
/// 适合单文件大小通常 < 几 MB 的 JSONL；如果以后单文件巨大可换 chunk 流。
enum JSONLLineReader {
    /// - Returns: (lines, newOffset)。如果文件不存在 / 读失败，返回 nil。
    nonisolated static func read(url: URL, fromOffset offset: UInt64) -> (lines: [String], newOffset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        if offset >= end {
            return (lines: [], newOffset: end)
        }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
        // 必须按整行切：最后一行如果没有换行结尾，则保留为下次偏移之前的残行 → 简单起见，把最后未结束的部分丢回 offset
        guard !data.isEmpty else {
            return (lines: [], newOffset: end)
        }
        let newline = UInt8(ascii: "\n")
        var lastNewline: Int = -1
        for i in stride(from: data.count - 1, through: 0, by: -1) {
            if data[i] == newline {
                lastNewline = i
                break
            }
        }
        let completePart: Data
        let newOffset: UInt64
        if lastNewline < 0 {
            // 整段没有换行 → 全是残行，不消费
            return (lines: [], newOffset: offset)
        } else {
            completePart = data.subdata(in: 0..<(lastNewline + 1))
            newOffset = offset + UInt64(lastNewline + 1)
        }
        let text = String(data: completePart, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines: lines, newOffset: newOffset)
    }
}

/// JSONL 行时间戳解析。ISO8601DateFormatter 创建成本很高，不能按行新建；
/// 这里静态复用两个固定配置的实例（含 / 不含小数秒各一个）。实例创建后
/// 不再修改配置，Foundation 的 formatter 在只读并发使用下是线程安全的，
/// 因此对 Sendable 检查用 nonisolated(unsafe) 显式豁免。
enum JSONLTimestamp {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated static func parse(_ s: String) -> Date? {
        if let d = fractional.date(from: s) { return d }
        return plain.date(from: s)
    }
}

/// 递归列出某目录下后缀为 .jsonl 的文件。
enum JSONLDirectoryEnumerator {
    nonisolated static func files(at root: URL) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in it {
            if url.pathExtension.lowercased() == "jsonl" {
                result.append(url)
            }
        }
        return result
    }
}
