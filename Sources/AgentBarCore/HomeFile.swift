import Foundation

/// home 目录下的一个数据文件。负责存在性判断、读取，以及在错误信息里显示 "~/..." 形式的路径。
struct HomeFile: Sendable {
    let home: URL
    /// 相对 home 的路径，例如 ".codex/auth.json"。
    let relativePath: String

    var url: URL { home.appendingPathComponent(relativePath) }

    /// 给用户看的路径，例如 "~/.codex/auth.json"。
    var displayPath: String { "~/" + relativePath }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func read() throws -> Data {
        guard exists else { throw ProviderError.fileNotFound(displayPath) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ProviderError.unreadable("无法读取 \(displayPath)")
        }
    }
}

enum DateParsing {
    /// 解析 ISO 8601 时间，带不带小数秒都可以。
    static func iso8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
