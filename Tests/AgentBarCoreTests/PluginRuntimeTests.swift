import Foundation
import Testing
@testable import AgentBarCore

/// 在临时 home 下生成插件目录 `.config/agentbar/plugins/<id>/`。
private struct PluginFixture {
    let home: TestHome
    let id: String

    init(id: String = "example", manifest: String? = nil, script: String? = nil, home: TestHome? = nil) throws {
        self.home = try home ?? TestHome()
        self.id = id
        try self.home.write(manifest ?? #"{"apiVersion":1,"id":"\#(id)","name":"Example","command":["./status"]}"#,
                            to: "\(Self.root)/\(id)/plugin.json")
        if let script { try writeScript(script) }
    }

    static let root = ".config/agentbar/plugins"

    var directory: URL { home.path("\(Self.root)/\(id)") }

    func writeScript(_ body: String, name: String = "status") throws {
        try home.write("#!/bin/sh\n" + body, to: "\(Self.root)/\(id)/\(name)")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent(name).path)
    }

    func provider(timeoutSeconds: Int = 20) throws -> PluginProvider {
        var manifest = try PluginManifest.parse(Data(contentsOf: directory.appendingPathComponent("plugin.json")))
        manifest.timeoutSeconds = timeoutSeconds
        return PluginProvider(manifest: manifest, directory: directory, home: home.url)
    }
}

private func providerError(_ body: () async throws -> Void) async -> ProviderError? {
    do {
        try await body()
        return nil
    } catch let error as ProviderError {
        return error
    } catch {
        Issue.record("意外的错误类型：\(error)")
        return nil
    }
}

@Suite struct ProcessRunnerTests {
    private func run(_ script: String, timeout: TimeInterval = 5, limit: Int = 65_536) async throws -> ProcessRunner.Output {
        let home = try TestHome()
        try home.write(script, to: "run.sh")
        return try await ProcessRunner.run(
            ["/bin/sh", "run.sh"], in: home.url, environment: ["GREETING": "hi"], timeout: timeout, outputLimit: limit)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let output = try await run(#"echo "out $GREETING"; echo err >&2; exit 3"#)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out hi\n")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err\n")
        #expect(output.exitCode == 3)
    }

    @Test func runsInTheGivenDirectoryWithEmptyStdin() async throws {
        let output = try await run(#"pwd -P; cat; echo done"#)
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        #expect(lines.first?.contains("AgentBarTests-") == true)
        #expect(lines.last == "done")
    }

    @Test func timesOut() async throws {
        let start = Date()
        await #expect(throws: ProcessRunner.Failure.timedOut) {
            _ = try await run("sleep 10", timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func timesOutEvenIfAChildKeepsThePipeOpen() async throws {
        let start = Date()
        await #expect(throws: ProcessRunner.Failure.timedOut) {
            _ = try await run("sleep 10 & sleep 10", timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func stopsWhenOutputIsTooLarge() async throws {
        await #expect(throws: ProcessRunner.Failure.outputTooLarge) {
            _ = try await run("yes 0123456789", limit: 1000)
        }
    }

    @Test func launchFailure() async throws {
        await #expect(throws: ProcessRunner.Failure.self) {
            _ = try await ProcessRunner.run(
                ["/nonexistent/tool"], in: FileManager.default.temporaryDirectory,
                environment: [:], timeout: 1, outputLimit: 100)
        }
    }
}

@Suite struct PluginProviderTests {
    @Test func identity() throws {
        let fixture = try PluginFixture()
        let provider = try fixture.provider()
        #expect(provider.id == "example")
        #expect(provider.displayName == "Example")
    }

    @Test func status() async throws {
        let fixture = try PluginFixture(script: #"echo '{"plan":"Pro","state":"active","account":"a@b.com"}'"#)
        let status = try await fixture.provider().fetchStatus()
        #expect(status.plan.displayName == "Pro")
        #expect(status.state == .active)
        #expect(status.account == "a@b.com")
    }

    @Test func environment() async throws {
        let fixture = try PluginFixture(script: #"""
        [ "$AGENTBAR_PLUGIN_API" = 1 ] || exit 9
        [ "$(cd "$AGENTBAR_PLUGIN_DIR" && pwd -P)" = "$(pwd -P)" ] || exit 8
        command -v sh >/dev/null || exit 7
        echo '{"plan":"Pro","state":"active"}'
        """#)
        let status = try await fixture.provider().fetchStatus()
        #expect(status.plan.displayName == "Pro")
    }

    @Test func interpreterFromPath() async throws {
        let fixture = try PluginFixture(
            manifest: #"{"apiVersion":1,"id":"example","name":"Example","command":["sh","status.sh"]}"#)
        try fixture.home.write(#"echo '{"plan":"Free","state":"active"}'"#, to: "\(PluginFixture.root)/example/status.sh")
        #expect(try await fixture.provider().fetchStatus().plan.displayName == "Free")
    }

    @Test func reportedError() async throws {
        let fixture = try PluginFixture(script: #"echo '{"error":"找不到 ~/.example/config.json"}'"#)
        let error = await providerError { _ = try await fixture.provider().fetchStatus() }
        #expect(error == .unreadable("找不到 ~/.example/config.json"))
    }

    @Test func nonZeroExitUsesLastStderrLine() async throws {
        let fixture = try PluginFixture(script: "echo starting >&2; echo 'token expired' >&2; echo >&2; exit 2")
        let error = await providerError { _ = try await fixture.provider().fetchStatus() }
        #expect(error == .unreadable("token expired"))
    }

    @Test func nonZeroExitWithoutStderr() async throws {
        let fixture = try PluginFixture(script: "exit 4")
        let error = await providerError { _ = try await fixture.provider().fetchStatus() }
        #expect(error == .unreadable("插件异常退出（退出码 4）"))
    }

    @Test func invalidOutput() async throws {
        let fixture = try PluginFixture(script: #"echo '{"plan":"Pro"}'"#)
        let error = await providerError { _ = try await fixture.provider().fetchStatus() }
        #expect(error == .unreadable("插件输出格式错误：state：缺少该字段"))
    }

    @Test func timeout() async throws {
        let fixture = try PluginFixture(script: "sleep 10")
        let error = await providerError { _ = try await fixture.provider(timeoutSeconds: 1).fetchStatus() }
        #expect(error == .unreadable("插件运行超时（1 秒）"))
    }

    @Test func missingCommand() async throws {
        let fixture = try PluginFixture()  // 没有 status 脚本
        let error = await providerError { _ = try await fixture.provider().fetchStatus() }
        #expect(error != nil)
    }

    @Test func detectIsInstalled() throws {
        let home = try TestHome()
        let manifest = #"{"apiVersion":1,"id":"example","name":"Example","command":["./status"],"detect":["~/.example/config.json","/nonexistent"]}"#
        let fixture = try PluginFixture(manifest: manifest, home: home)
        #expect(try !fixture.provider().isInstalled())
        try home.write("{}", to: ".example/config.json")
        #expect(try fixture.provider().isInstalled())
    }

    @Test func detectRelativeToPluginDirectory() throws {
        let manifest = #"{"apiVersion":1,"id":"example","name":"Example","command":["./status"],"detect":["marker"]}"#
        let fixture = try PluginFixture(manifest: manifest)
        #expect(try !fixture.provider().isInstalled())
        try fixture.home.write("", to: "\(PluginFixture.root)/example/marker")
        #expect(try fixture.provider().isInstalled())
    }

    @Test func noDetectMeansInstalled() throws {
        #expect(try PluginFixture().provider().isInstalled())
    }
}

@Suite struct PluginDiscoveryTests {
    @Test func noPluginFolder() throws {
        let home = try TestHome()
        #expect(PluginDiscovery.discover(home: home.url, reservedIDs: []).isEmpty)
        #expect(PluginDiscovery.root(home: home.url).path == home.path(".config/agentbar/plugins").path)
    }

    @Test func findsValidAndInvalidPlugins() throws {
        let home = try TestHome()
        _ = try PluginFixture(id: "zeta", home: home)
        _ = try PluginFixture(id: "alpha", home: home)
        _ = try PluginFixture(id: "broken", manifest: #"{"apiVersion":1,"id":"broken"}"#, home: home)
        _ = try PluginFixture(id: "codex", manifest: #"{"apiVersion":1,"id":"codex","name":"X","command":["x"]}"#, home: home)
        _ = try PluginFixture(id: "renamed", manifest: #"{"apiVersion":1,"id":"other","name":"X","command":["x"]}"#, home: home)
        try home.write("", to: "\(PluginFixture.root)/empty-folder/readme.txt")
        try home.write("", to: "\(PluginFixture.root)/.hidden/plugin.json")
        try home.write("", to: "\(PluginFixture.root)/stray-file.json")

        let entries = PluginDiscovery.discover(home: home.url, reservedIDs: ["codex"])

        #expect(entries.map(\.directory.lastPathComponent) == ["alpha", "broken", "codex", "empty-folder", "renamed", "zeta"])
        #expect(entries.map { $0.manifest?.id } == ["alpha", nil, nil, nil, nil, "zeta"])
        #expect(entries[1].error?.field == "name")
        #expect(entries[2].error?.field == "id")
        #expect(entries[3].error?.message == "缺少 plugin.json")
        #expect(entries[4].error?.field == "id")
    }

    @Test func builtInIDsAreReserved() {
        #expect(ProviderRegistry.builtInIDs == ["claude-code", "codex", "cursor", "gemini-cli", "minimax-code", "mmx"])
    }
}
