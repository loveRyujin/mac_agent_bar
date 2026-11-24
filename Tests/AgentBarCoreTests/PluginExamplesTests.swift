import Foundation
import Testing
@testable import AgentBarCore

/// 仓库里 `skills/agentbar-plugin/examples/` 下的示例插件：用临时 home 里的假数据真正运行一遍。
@Suite struct PluginExamplesTests {
    private static let examples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AgentBarCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // 仓库根目录
        .appendingPathComponent("skills/agentbar-plugin/examples", isDirectory: true)

    private func provider(_ id: String, home: TestHome) throws -> PluginProvider {
        let directory = Self.examples.appendingPathComponent(id, isDirectory: true)
        let manifest = try PluginDiscovery.load(directory, reservedIDs: ProviderRegistry.builtInIDs).get()
        return PluginProvider(manifest: manifest, directory: directory, home: home.url)
    }

    private func date(_ string: String) -> Date { DateParsing.iso8601(string)! }

    @Test func allExamplesHaveValidManifests() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.examples.path).filter { !$0.hasPrefix(".") }
        #expect(folders.sorted() == ["example-cli", "example-json-file", "example-sqlite"])
        for folder in folders {
            let result = PluginDiscovery.load(Self.examples.appendingPathComponent(folder), reservedIDs: ProviderRegistry.builtInIDs)
            #expect(throws: Never.self, "\(folder)") { try result.get() }
        }
    }

    // MARK: - JSON 文件

    @Test func jsonFile() async throws {
        let home = try TestHome()
        try home.write(#"""
        {"email":"you@example.com","plan":"pro",
         "subscription":{"status":"trialing","renews_at":"2026-12-01T00:00:00Z"},
         "quota":{"daily":{"used":120,"limit":500,"reset_at":"2026-11-25T00:00:00Z"}}}
        """#, to: ".example-agent/account.json")
        let provider = try provider("example-json-file", home: home)
        #expect(provider.isInstalled())

        let status = try await provider.fetchStatus()

        #expect(status.plan.displayName == "Pro")
        #expect(status.state == .trial)
        #expect(status.account == "you@example.com")
        #expect(status.periodEnd == date("2026-12-01T00:00:00Z"))
        #expect(status.usage.usage?.windows == [
            UsageWindow(id: "0", windowMinutes: 1440, usedPercent: 24, resetsAt: date("2026-11-25T00:00:00Z")),
        ])
    }

    @Test func jsonFileSignedOutAndMissing() async throws {
        let home = try TestHome()
        let provider = try provider("example-json-file", home: home)
        #expect(!provider.isInstalled())
        let run = await provider.execute()
        #expect(run.isReportedError)
        #expect(run.result.failureMessage == "找不到 ~/.example-agent/account.json")

        try home.write(#"{"plan":"free"}"#, to: ".example-agent/account.json")
        #expect(try await provider.fetchStatus().state == .signedOut)

        try home.write("{not json", to: ".example-agent/account.json")
        #expect(await provider.execute().result.failureMessage == "~/.example-agent/account.json 格式无法解析")
    }

    // MARK: - SQLite

    private func makeDatabase(in home: TestHome, rows: [(String, String)]) async throws {
        try home.write(Data(), to: ".example-agent/.keep")
        let values = rows.map { "('\($0.0)', '\($0.1)')" }.joined(separator: ", ")
        let sql = "CREATE TABLE items (key TEXT PRIMARY KEY, value TEXT);"
            + (rows.isEmpty ? "" : " INSERT INTO items VALUES \(values);")
        let output = try await ProcessRunner.run(
            ["/usr/bin/sqlite3", home.path(".example-agent/state.db").path, sql],
            in: home.url, environment: [:], timeout: 10, outputLimit: 10_000)
        #expect(output.exitCode == 0)
    }

    @Test func sqlite() async throws {
        let home = try TestHome()
        try await makeDatabase(in: home, rows: [
            ("email", "you@example.com"), ("plan", "Team"), ("status", "active"), ("renews_at", "2026-12-01T00:00:00Z"),
        ])
        let provider = try provider("example-sqlite", home: home)
        #expect(provider.isInstalled())

        let status = try await provider.fetchStatus()

        #expect(status.plan.displayName == "Team")
        #expect(status.state == .active)
        #expect(status.account == "you@example.com")
        #expect(status.periodEnd == date("2026-12-01T00:00:00Z"))
        #expect(status.usage == .unsupported)
    }

    @Test func sqliteEmptyAndMissing() async throws {
        let home = try TestHome()
        let provider = try provider("example-sqlite", home: home)
        #expect(await provider.execute().result.failureMessage == "找不到 ~/.example-agent/state.db")

        try await makeDatabase(in: home, rows: [])
        let status = try await provider.fetchStatus()
        #expect(status.plan.displayName == "未知套餐")
        #expect(status.state == .unknown)
        #expect(status.account == nil)
    }

    // MARK: - 命令行工具

    private func installFakeCLI(in home: TestHome, script: String) throws {
        try home.write("#!/bin/sh\n" + script, to: ".local/bin/example-cli")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: home.path(".local/bin/example-cli").path)
    }

    @Test func cli() async throws {
        let home = try TestHome()
        try installFakeCLI(in: home, script: #"""
        [ "$1 $2" = "quota --json" ] || exit 9
        echo '{"plan":"Pro","email":"you@example.com","limits":[{"window_minutes":300,"remaining_percent":60,"resets_at":"2026-11-25T03:00:00Z"},{"window_minutes":10080,"remaining_percent":95}]}'
        """#)
        let status = try await provider("example-cli", home: home).fetchStatus()

        #expect(status.plan.displayName == "Pro")
        #expect(status.account == "you@example.com")
        #expect(status.usage.usage?.windows.map(\.usedPercent) == [40, 5])
        #expect(status.usage.usage?.windows.map(\.name) == ["5 小时", "每周"])
    }

    @Test func cliErrors() async throws {
        let home = try TestHome()
        let provider = try provider("example-cli", home: home)
        // 临时 home 的 ~/.local/bin 里没有 example-cli；用户自己的机器上也不会有这个虚构的工具
        #expect(await provider.execute().result.failureMessage == "找不到 example-cli，请先安装")

        try installFakeCLI(in: home, script: "echo 'Error: not logged in' >&2; exit 1")
        #expect(try await provider.fetchStatus().state == .signedOut)

        try installFakeCLI(in: home, script: "echo 'rate limited' >&2; exit 1")
        #expect(await provider.execute().result.failureMessage == "rate limited")

        try installFakeCLI(in: home, script: #"echo '{"plan":"Free"}'"#)
        #expect(try await provider.fetchStatus().usage == .failed("example-cli 没有返回额度"))
    }
}

private extension Result where Failure == ProviderError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}
