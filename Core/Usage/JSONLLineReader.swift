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

/// JSONL 行时间戳解析。除了 formatter 实例创建成本高（不能按行新建，这里静态复用
/// 两个固定配置的实例），`date(from:)` 单次调用本身也很贵——内部要走 CFDateFormatter
/// 的通用格式状态机，实测占整轮日志扫描 CPU 的一半以上。JSONL 时间戳形状固定，
/// 先用按字节的手写解析走完绝大多数行，形状不符再回退到 formatter，避免收窄行为。
/// formatter 实例创建后不再修改配置，Foundation 的 formatter 在只读并发使用下是
/// 线程安全的，因此对 Sendable 检查用 nonisolated(unsafe) 显式豁免。
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

    /// 小数秒位数 → 除数，避免逐位累乘带来的浮点误差和 `pow` 调用。
    nonisolated private static let fractionScales: [Double] = [
        1, 10, 100, 1_000, 10_000, 100_000,
        1_000_000, 10_000_000, 100_000_000, 1_000_000_000,
    ]

    nonisolated static func parse(_ s: String) -> Date? {
        if let fast = fastParse(s) { return fast }
        if let d = fractional.date(from: s) { return d }
        return plain.date(from: s)
    }

    /// 手写解析 `YYYY-MM-DDTHH:MM:SS[.fff…][Z|±HH[:]MM]`（与 `.withInternetDateTime`
    /// 接受的形状一致）。任何一处不符合就返回 nil，交回 formatter 兜底。
    /// second 上限 59：withInternetDateTime 连标准闰秒位（23:59:60）都拒绝，
    /// 这里同样拒绝，避免 fast 路径比 formatter 更宽容导致结果不一致。
    nonisolated private static func fastParse(_ s: String) -> Date? {
        let parsed: Date?? = s.utf8.withContiguousStorageIfAvailable { buffer in
            parseInternetDateTime(buffer)
        }
        return parsed ?? nil
    }

    nonisolated private static func parseInternetDateTime(
        _ b: UnsafeBufferPointer<UInt8>
    ) -> Date? {
        guard b.count >= 19,
              b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"),
              b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              let year = integer(in: b, from: 0, count: 4),
              let month = integer(in: b, from: 5, count: 2),
              let day = integer(in: b, from: 8, count: 2),
              let hour = integer(in: b, from: 11, count: 2),
              let minute = integer(in: b, from: 14, count: 2),
              let second = integer(in: b, from: 17, count: 2),
              (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var index = 19
        var fraction: Double = 0
        if index < b.count, b[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            var value = 0
            while index < b.count, let digit = digitValue(b[index]) {
                // 超出 Double 有效精度的尾数直接丢弃，避免溢出。
                if digits < fractionScales.count - 1 {
                    value = value * 10 + digit
                    digits += 1
                }
                index += 1
            }
            guard digits > 0 else { return nil }
            fraction = Double(value) / fractionScales[digits]
        }

        // `.withInternetDateTime` 要求必须带时区，缺时区的输入原本解析失败；
        // 这里同样拒绝，交回 formatter，避免把原来被跳过的行变成有效条目。
        guard index < b.count else { return nil }
        var offsetSeconds = 0
        let marker = b[index]
        if marker == UInt8(ascii: "Z") || marker == UInt8(ascii: "z") {
            index += 1
        } else if marker == UInt8(ascii: "+") || marker == UInt8(ascii: "-") {
            let sign = marker == UInt8(ascii: "+") ? 1 : -1
            index += 1
            guard let offsetHour = integer(in: b, from: index, count: 2) else { return nil }
            index += 2
            if index < b.count, b[index] == UInt8(ascii: ":") { index += 1 }
            var offsetMinute = 0
            if let value = integer(in: b, from: index, count: 2) {
                offsetMinute = value
                index += 2
            }
            offsetSeconds = sign * (offsetHour * 3_600 + offsetMinute * 60)
        } else {
            return nil
        }
        // 还有尾巴说明形状超出这里的假设，不猜，交给 formatter。
        guard index == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    nonisolated private static func digitValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }

    nonisolated private static func integer(
        in b: UnsafeBufferPointer<UInt8>,
        from start: Int,
        count: Int
    ) -> Int? {
        guard start >= 0, start + count <= b.count else { return nil }
        var value = 0
        for offset in start..<(start + count) {
            guard let digit = digitValue(b[offset]) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    /// 民用日期 → 距 1970-01-01 的天数（proleptic Gregorian，Howard Hinnant 的
    /// days_from_civil；纯整数运算，不经过 Calendar）。
    nonisolated private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400                                            // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// JSONL 枚举阶段取得的稳定文件元数据，供 Scanner 判断是否需要读取。
/// 避免枚举后再为每个文件重复查询 mtime / size。
struct JSONLFileDescriptor: Sendable {
    var url: URL
    var modificationTime: TimeInterval
    var size: UInt64

    var path: String { url.path }
}

/// 递归列出某目录下后缀为 .jsonl 的文件，并同时取得增量扫描所需元数据。
enum JSONLDirectoryEnumerator {
    /// - Parameter minimumMtime: 非 nil 时只返回修改时间不早于该时刻的文件。
    ///   供周期用量的受限重建过滤"最近窗口之外"的旧日志使用；nil 时行为与原来一致。
    nonisolated static func files(at root: URL, minimumMtime: Date? = nil) -> [JSONLFileDescriptor] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let it = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [JSONLFileDescriptor] = []
        for case let url as URL in it {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
            ])
            let modificationDate = values?.contentModificationDate
            if let minimumMtime {
                guard let modificationDate, modificationDate >= minimumMtime else { continue }
            }
            result.append(JSONLFileDescriptor(
                url: url,
                modificationTime: modificationDate?.timeIntervalSince1970 ?? 0,
                size: UInt64(max(0, values?.fileSize ?? 0))
            ))
        }
        return result
    }
}
