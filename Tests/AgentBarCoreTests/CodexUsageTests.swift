import Foundation
import Testing
@testable import AgentBarCore

private func date(_ iso: String) -> Date { DateParsing.iso8601(iso)! }

/// 一行 token_count 事件（与 Codex 会话日志格式一致）。
private func rateLimitsLine(
    at timestamp: String, primary: Double, secondary: Double,
    primaryResets: Int = 1_794_296_603, secondaryResets: Int = 1_794_385_798
) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primary),"window_minutes":300,"resets_at":\(primaryResets)},"secondary":{"used_percent":\(secondary),"window_minutes":10080,"resets_at":\(secondaryResets)},"credits":{"has_credits":false}}}}
    """
}

private let messageLine = #"{"timestamp":"2026-11-10T02:40:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"会话内容，不应被解析"}]}}"#

private struct SessionFile {
    let path: String
    let lines: [String]
    var modified: Date
    var trailingPartialLine = false
}

private func makeHome(_ files: [SessionFile]) throws -> TestHome {
    let home = try TestHome()
    for file in files {
        var text = file.lines.joined(separator: "\n") + "\n"
        if file.trailingPartialLine { text += #"{"timestamp":"2026-11-10T03:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_pe"# }
        try home.write(text, to: ".codex/sessions/\(file.path)")
        try FileManager.default.setAttributes(
            [.modificationDate: file.modified], ofItemAtPath: home.path(".codex/sessions/\(file.path)").path)
    }
    return home
}

@Suite struct CodexUsageReaderTests {
    @Test func readsLatestSnapshotFromNewestFile() throws {
        let home = try makeHome([
            SessionFile(path: "2026/11/09/rollout-a.jsonl", lines: [
                messageLine,
                rateLimitsLine(at: "2026-11-10T02:00:00.000Z", primary: 10, secondary: 20),
                messageLine,
                rateLimitsLine(at: "2026-11-10T02:43:43.837Z", primary: 0, secondary: 26),
                messageLine,
            ], modified: date("2026-11-10T02:44:00Z")),
            SessionFile(path: "2026/11/04/rollout-b.jsonl", lines: [
                rateLimitsLine(at: "2026-11-04T12:00:00.000Z", primary: 99, secondary: 99),
            ], modified: date("2026-11-04T12:00:00Z")),
        ])

        let usage = try #require(CodexUsageReader(home: home.url).read().usage)

        #expect(usage.windows == [
            UsageWindow(id: "primary", windowMinutes: 300, usedPercent: 0,
                        resetsAt: Date(timeIntervalSince1970: 1_794_296_603)),
            UsageWindow(id: "secondary", windowMinutes: 10080, usedPercent: 26,
                        resetsAt: Date(timeIntervalSince1970: 1_794_385_798)),
        ])
        #expect(usage.capturedAt == date("2026-11-10T02:43:43.837Z"))
    }

    @Test func usesModificationTimeNotPath() throws {
        let home = try makeHome([
            SessionFile(path: "2026/11/09/old-name.jsonl", lines: [
                rateLimitsLine(at: "2026-11-09T00:00:00.000Z", primary: 1, secondary: 1),
            ], modified: date("2026-11-09T00:00:00Z")),
            SessionFile(path: "2026/11/03/resumed.jsonl", lines: [
                rateLimitsLine(at: "2026-11-11T00:00:00.000Z", primary: 55, secondary: 1),
            ], modified: date("2026-11-11T00:00:00Z")),
        ])
        let usage = try #require(CodexUsageReader(home: home.url).read().usage)
        #expect(usage.windows.first?.usedPercent == 55)
    }

    @Test func fallsBackToOlderFileWhenNewestHasNoSnapshot() throws {
        let home = try makeHome([
            SessionFile(path: "2026/11/10/new.jsonl", lines: [messageLine, messageLine],
                        modified: date("2026-11-10T00:00:00Z")),
            SessionFile(path: "2026/11/09/old.jsonl", lines: [
                rateLimitsLine(at: "2026-11-09T00:00:00.000Z", primary: 12, secondary: 34),
            ], modified: date("2026-11-09T00:00:00Z")),
        ])
        let usage = try #require(CodexUsageReader(home: home.url).read().usage)
        #expect(usage.windows.map(\.usedPercent) == [12, 34])
    }

    @Test func skipsPartialLastLineCorruptLinesAndNullRateLimits() throws {
        let home = try makeHome([
            SessionFile(path: "2026/11/10/a.jsonl", lines: [
                rateLimitsLine(at: "2026-11-10T01:00:00.000Z", primary: 40, secondary: 50),
                #"{"timestamp":"2026-11-10T02:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
                #"{"rate_limits": this is not json"#,
            ], modified: date("2026-11-10T02:00:00Z"), trailingPartialLine: true),
        ])
        let usage = try #require(CodexUsageReader(home: home.url).read().usage)
        #expect(usage.windows.map(\.usedPercent) == [40, 50])
    }

    @Test func findsSnapshotBeforeAVeryLongLine() throws {
        let longLine = #"{"type":"response_item","payload":{"text":""# + String(repeating: "x", count: 20_000) + #""}}"#
        let home = try makeHome([
            SessionFile(path: "2026/11/10/a.jsonl", lines: [
                rateLimitsLine(at: "2026-11-10T01:00:00.000Z", primary: 7, secondary: 8),
                longLine,
            ], modified: date("2026-11-10T02:00:00Z")),
        ])
        // 初始只读 1KB，需要逐步扩大才能找到
        let usage = try #require(CodexUsageReader(home: home.url, initialChunkSize: 1024).read().usage)
        #expect(usage.windows.map(\.usedPercent) == [7, 8])
    }

    @Test func noSessionsDirectoryIsNoData() throws {
        #expect(CodexUsageReader(home: try TestHome().url).read() == .noData)
    }

    @Test func sessionsWithoutSnapshotsIsNoData() throws {
        let home = try makeHome([
            SessionFile(path: "2026/11/10/a.jsonl", lines: [messageLine], modified: date("2026-11-10T00:00:00Z")),
        ])
        #expect(CodexUsageReader(home: home.url).read() == .noData)
    }

    @Test func missingSecondaryWindowIsAllowed() throws {
        let line = #"{"timestamp":"2026-11-10T01:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.5,"window_minutes":300,"resets_at":1794296603},"secondary":null}}}"#
        let home = try makeHome([
            SessionFile(path: "2026/11/10/a.jsonl", lines: [line], modified: date("2026-11-10T01:00:00Z")),
        ])
        let usage = try #require(CodexUsageReader(home: home.url).read().usage)
        #expect(usage.windows.map(\.id) == ["primary"])
        #expect(usage.windows.first?.usedPercent == 5.5)
    }
}
