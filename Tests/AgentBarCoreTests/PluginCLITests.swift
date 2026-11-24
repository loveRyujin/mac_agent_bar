import Foundation
import Testing
@testable import AgentBarCore

/// 运行一次命令，收集输出。
private struct CLIRun {
    let code: Int32
    let out: String
    let err: String

    init(_ arguments: [String], home: TestHome) async {
        let collector = Collector()
        code = await PluginCLI(home: home.url, out: { collector.append(\.out, $0) }, err: { collector.append(\.err, $0) })
            .run(arguments)
        out = collector.value(\.out)
        err = collector.value(\.err)
    }

    private final class Collector: @unchecked Sendable {
        struct Texts { var out = ""; var err = "" }
        private let lock = NSLock()
        private var texts = Texts()
        func append(_ key: WritableKeyPath<Texts, String>, _ line: String) { lock.withLock { texts[keyPath: key] += line + "\n" } }
        func value(_ key: KeyPath<Texts, String>) -> String { lock.withLock { texts[keyPath: key] } }
    }
}

private let root = ".config/agentbar/plugins"

private func writePlugin(_ id: String, in home: TestHome, manifest: String? = nil, script: String) throws {
    try home.write(manifest ?? #"{"apiVersion":1,"id":"\#(id)","name":"Example","command":["./status"]}"#,
                   to: "\(root)/\(id)/plugin.json")
    try home.write("#!/bin/sh\n" + script, to: "\(root)/\(id)/status")
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: home.path("\(root)/\(id)/status").path)
}

@Suite struct PluginCLITests {
    @Test func usage() async throws {
        let home = try TestHome()
        for arguments in [[], ["help"], ["frobnicate"], ["check"], ["new"], ["check", "a", "b"]] {
            let run = await CLIRun(arguments, home: home)
            #expect(run.code == (arguments == ["help"] ? 0 : 2), "\(arguments)")
            #expect((run.out + run.err).contains("agentbar plugin check"))
        }
    }

    @Test func checkPassesAndShowsWhatThePanelShows() async throws {
        let home = try TestHome()
        try writePlugin("example", in: home, script: #"""
        echo '{"plan":"Pro","planShortName":"P","state":"trial","account":"a@b.com","periodEnd":"2026-12-01T12:00:00Z",
         "usage":{"windows":[{"windowMinutes":300,"usedPercent":35.5,"resetsAt":"2026-11-25T00:00:00Z"},
                             {"label":"每周","usedPercent":72}]}}'
        """#)

        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)

        #expect(run.code == 0, "\(run.err)")
        for expected in ["Example", "Pro", "P", "试用", "a@b.com", "2026-12-01", "5 小时", "35.5%", "每周", "72%", "通过"] {
            #expect(run.out.contains(expected), "缺少 \(expected)：\n\(run.out)")
        }
    }

    @Test func checkReportsManifestErrors() async throws {
        let home = try TestHome()
        try writePlugin("example", in: home, manifest: #"{"apiVersion":1,"id":"Example","name":"X","command":["./status"]}"#, script: "")
        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("plugin.json"))
        #expect(run.err.contains("id："))
    }

    @Test func checkRequiresFolderNameToMatchID() async throws {
        let home = try TestHome()
        try writePlugin("folder", in: home, manifest: #"{"apiVersion":1,"id":"other","name":"X","command":["./status"]}"#, script: "")
        let run = await CLIRun(["check", home.path("\(root)/folder").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("文件夹名"))
    }

    @Test func checkRejectsBuiltInIDs() async throws {
        let home = try TestHome()
        try writePlugin("codex", in: home, manifest: #"{"apiVersion":1,"id":"codex","name":"X","command":["./status"]}"#, script: "")
        let run = await CLIRun(["check", home.path("\(root)/codex").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("内置"))
    }

    @Test func checkReportsOutputErrorsWithTheRawOutput() async throws {
        let home = try TestHome()
        try writePlugin("example", in: home, script: #"echo '{"plan":"Pro"}'; echo debug-info >&2"#)
        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("state：缺少该字段"))
        #expect(run.err.contains(#"{"plan":"Pro"}"#))
        #expect(run.err.contains("debug-info"))
    }

    @Test func checkTreatsReportedErrorAsValidOutput() async throws {
        let home = try TestHome()
        try writePlugin("example", in: home, script: #"echo '{"error":"还没有登录 Example"}'"#)
        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)
        #expect(run.code == 0)
        #expect(run.out.contains("还没有登录 Example"))
    }

    @Test func checkReportsNonZeroExit() async throws {
        let home = try TestHome()
        try writePlugin("example", in: home, script: "echo boom >&2; exit 3")
        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("boom"))
    }

    @Test func checkMentionsDetect() async throws {
        let home = try TestHome()
        let manifest = #"{"apiVersion":1,"id":"example","name":"X","command":["./status"],"detect":["~/.example"]}"#
        try writePlugin("example", in: home, manifest: manifest, script: #"echo '{"plan":"Pro","state":"active"}'"#)
        let run = await CLIRun(["check", home.path("\(root)/example").path], home: home)
        #expect(run.code == 0)
        #expect(run.out.contains("~/.example"))
        #expect(run.out.contains("未安装"))
    }

    @Test func checkMissingFolder() async throws {
        let home = try TestHome()
        let run = await CLIRun(["check", home.path("nope").path], home: home)
        #expect(run.code == 1)
        #expect(run.err.contains("plugin.json"))
    }

    @Test func newCreatesAScaffoldThatPassesCheck() async throws {
        let home = try TestHome()
        let created = await CLIRun(["new", "my-agent"], home: home)
        #expect(created.code == 0, "\(created.err)")
        let directory = home.path("\(root)/my-agent")
        #expect(created.out.contains(directory.path))
        #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("status").path))

        let checked = await CLIRun(["check", directory.path], home: home)
        #expect(checked.code == 0, "\(checked.err)")
    }

    @Test func newIntoAnotherDirectory() async throws {
        let home = try TestHome()
        let run = await CLIRun(["new", "my-agent", "--dir", home.path("work").path], home: home)
        #expect(run.code == 0, "\(run.err)")
        #expect(FileManager.default.fileExists(atPath: home.path("work/my-agent/plugin.json").path))
    }

    @Test func newRefusesBadIDsAndExistingFolders() async throws {
        let home = try TestHome()
        #expect(await CLIRun(["new", "My Agent"], home: home).code == 1)
        #expect(await CLIRun(["new", "cursor"], home: home).code == 1)
        #expect(await CLIRun(["new", "ok"], home: home).code == 0)
        let again = await CLIRun(["new", "ok"], home: home)
        #expect(again.code == 1)
        #expect(again.err.contains("已存在"))
    }
}
