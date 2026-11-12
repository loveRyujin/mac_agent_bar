import Foundation

/// 从 Codex 会话日志（`~/.codex/sessions/**/*.jsonl`）中读取最新的额度快照。
///
/// 每次请求后 Codex 会追加一行 `token_count` 事件，其中的 `rate_limits` 是当时的额度快照。
/// 日志可能很多、很大：按修改时间从新到旧查找，每个文件只读末尾（不够再逐步扩大），
/// 只解析含 `"rate_limits"` 的行，且只取额度字段，不接触会话内容。
struct CodexUsageReader {
    private let sessionsDirectory: URL
    private let initialChunkSize: Int
    /// 最多查看多少个最新的会话文件。
    private let maxFiles = 10

    init(home: URL, initialChunkSize: Int = 64 * 1024) {
        sessionsDirectory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.initialChunkSize = initialChunkSize
    }

    func read() -> UsageAvailability {
        for file in newestSessionFiles() {
            if let usage = latestSnapshot(in: file) {
                return .available(usage)
            }
        }
        return .noData
    }

    private func newestSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, modified))
        }
        return files.sorted { $0.modified > $1.modified }.prefix(maxFiles).map(\.url)
    }

    /// 从文件末尾往前找最后一条有效的额度快照。
    private func latestSnapshot(in file: URL) -> Usage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        var chunkSize = UInt64(initialChunkSize)
        while true {
            let start = size > chunkSize ? size - chunkSize : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start))
            else { return nil }

            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // 不是从文件开头读的，第一行可能不完整
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                if let usage = Self.parse(line: Data(line)) { return usage }
            }
            if start == 0 { return nil }
            chunkSize *= 4
        }
    }

    private static let marker = Data(#""rate_limits""#.utf8)

    /// 只解析含 `"rate_limits"` 的行；格式不对、不完整或 `rate_limits` 为空时返回 nil。
    static func parse(line: Data) -> Usage? {
        guard line.range(of: marker) != nil,
              let event = try? JSONDecoder().decode(TokenCountEvent.self, from: line),
              let limits = event.payload.rateLimits
        else { return nil }

        let windows = [("primary", limits.primary), ("secondary", limits.secondary)]
            .compactMap { id, window -> UsageWindow? in
                guard let window else { return nil }
                return UsageWindow(
                    id: id,
                    windowMinutes: window.windowMinutes,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) })
            }
        guard !windows.isEmpty else { return nil }
        return Usage(windows: windows, capturedAt: event.timestamp.flatMap(DateParsing.iso8601))
    }
}

// MARK: - 日志格式（只建模额度相关字段）

private struct TokenCountEvent: Decodable {
    let timestamp: String?
    let payload: Payload

    struct Payload: Decodable {
        let rateLimits: RateLimits?

        private enum CodingKeys: String, CodingKey {
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int?
        /// Unix 时间戳（秒）。
        let resetsAt: Double?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
    }
}
