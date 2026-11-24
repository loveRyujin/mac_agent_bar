import Foundation
import Testing
@testable import AgentBarCore

private func manifest(_ json: String, reservedIDs: Set<String> = []) throws(PluginFormatError) -> PluginManifest {
    try PluginManifest.parse(Data(json.utf8), reservedIDs: reservedIDs)
}

private func output(_ json: String) throws(PluginFormatError) -> PluginOutput {
    try PluginOutput.parse(Data(json.utf8))
}

private func date(_ string: String) -> Date { DateParsing.iso8601(string)! }

/// 断言解析失败，并且错误指向 `field`。
private func expectError(field: String?, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("应当解析失败（\(field ?? "整体")）")
    } catch let error as PluginFormatError {
        #expect(error.field == field, "\(error.message)")
    } catch {
        Issue.record("意外的错误类型：\(error)")
    }
}

@Suite struct PluginManifestTests {
    @Test func minimal() throws {
        let m = try manifest(#"{"apiVersion":1,"id":"example","name":"Example","command":["./status"]}"#)
        #expect(m == PluginManifest(id: "example", name: "Example", command: ["./status"], detect: [], timeoutSeconds: 20))
    }

    @Test func full() throws {
        let m = try manifest(#"""
        {"apiVersion":1,"id":"my-agent-2","name":"My Agent","command":["python3","status.py"],
         "detect":["~/.my-agent/config.json","/opt/my-agent"],"timeoutSeconds":45,"extra":true}
        """#)
        #expect(m.id == "my-agent-2")
        #expect(m.command == ["python3", "status.py"])
        #expect(m.detect == ["~/.my-agent/config.json", "/opt/my-agent"])
        #expect(m.timeoutSeconds == 45)
    }

    @Test func notAnObject() {
        expectError(field: nil) { _ = try manifest("[1]") }
        expectError(field: nil) { _ = try manifest("not json") }
    }

    @Test func apiVersion() {
        expectError(field: "apiVersion") { _ = try manifest(#"{"id":"a","name":"A","command":["x"]}"#) }
        expectError(field: "apiVersion") { _ = try manifest(#"{"apiVersion":2,"id":"a","name":"A","command":["x"]}"#) }
        expectError(field: "apiVersion") { _ = try manifest(#"{"apiVersion":"1","id":"a","name":"A","command":["x"]}"#) }
    }

    @Test(arguments: ["", "Example", "my_agent", "-a", "a-", "a--b", "中文"])
    func invalidID(id: String) {
        expectError(field: "id") { _ = try manifest(#"{"apiVersion":1,"id":"\#(id)","name":"A","command":["x"]}"#) }
    }

    @Test func reservedID() {
        expectError(field: "id") {
            _ = try manifest(#"{"apiVersion":1,"id":"codex","name":"A","command":["x"]}"#, reservedIDs: ["codex"])
        }
    }

    @Test func name() {
        expectError(field: "name") { _ = try manifest(#"{"apiVersion":1,"id":"a","command":["x"]}"#) }
        expectError(field: "name") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":" ","command":["x"]}"#) }
    }

    @Test func command() {
        expectError(field: "command") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A"}"#) }
        expectError(field: "command") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":[]}"#) }
        expectError(field: "command") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":"./status"}"#) }
        expectError(field: "command[0]") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":[""]}"#) }
        expectError(field: "command[1]") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":["x",1]}"#) }
    }

    @Test func detect() {
        expectError(field: "detect") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":["x"],"detect":"~/.a"}"#) }
        expectError(field: "detect[0]") { _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":["x"],"detect":[""]}"#) }
    }

    @Test(arguments: ["0", "61", "1.5", "\"20\"", "true"])
    func invalidTimeout(value: String) {
        expectError(field: "timeoutSeconds") {
            _ = try manifest(#"{"apiVersion":1,"id":"a","name":"A","command":["x"],"timeoutSeconds":\#(value)}"#)
        }
    }
}

@Suite struct PluginOutputTests {
    @Test func full() throws {
        let result = try output(#"""
        {"plan":"Pro","planShortName":"P","state":"trial","account":"user@example.com","organization":"Org",
         "periodEnd":"2026-12-01T00:00:00Z",
         "usage":{"windows":[
            {"label":"每日","usedPercent":42.5,"resetsAt":"2026-11-25T00:00:00Z"},
            {"windowMinutes":10080,"usedPercent":10}],
          "capturedAt":"2026-11-24T08:00:00.000Z"},
         "somethingNew":1}
        """#)
        #expect(result == .status(SubscriptionStatus(
            plan: Plan(rawValue: "Pro", displayName: "Pro", shortName: "P"),
            state: .trial,
            account: "user@example.com",
            organization: "Org",
            periodEnd: date("2026-12-01T00:00:00Z"),
            usage: .available(Usage(
                windows: [
                    UsageWindow(id: "0", windowMinutes: nil, usedPercent: 42.5,
                                resetsAt: date("2026-11-25T00:00:00Z"), label: "每日"),
                    UsageWindow(id: "1", windowMinutes: 10080, usedPercent: 10, resetsAt: nil),
                ],
                capturedAt: date("2026-11-24T08:00:00Z"))))))
    }

    @Test func minimal() throws {
        let result = try output(#"{"plan":"Free","state":"active","account":null}"#)
        #expect(result == .status(SubscriptionStatus(
            plan: Plan(rawValue: "Free", displayName: "Free"), state: .active, usage: .unsupported)))
    }

    @Test(arguments: [
        ("active", SubscriptionStatus.State.active), ("trial", .trial), ("expired", .expired),
        ("signedOut", .signedOut), ("unknown", .unknown),
    ])
    func states(raw: String, expected: SubscriptionStatus.State) throws {
        guard case .status(let status) = try output(#"{"plan":"X","state":"\#(raw)"}"#) else {
            Issue.record("应当是订阅信息"); return
        }
        #expect(status.state == expected)
    }

    @Test func reportedError() throws {
        #expect(try output(#"{"error":"找不到 ~/.example/config.json"}"#) == .error("找不到 ~/.example/config.json"))
        // error 优先于其他字段
        #expect(try output(#"{"error":"登录已失效","plan":"Pro","state":"active"}"#) == .error("登录已失效"))
        // error 为 null 时视为没有错误
        #expect(try output(#"{"error":null,"plan":"Pro","state":"active"}"#)
            == .status(SubscriptionStatus(plan: Plan(rawValue: "Pro", displayName: "Pro"), state: .active)))
    }

    @Test func usageUnavailable() throws {
        guard case .status(let status) = try output(#"{"plan":"X","state":"active","usage":{"unavailable":"接口限流"}}"#) else {
            Issue.record("应当是订阅信息"); return
        }
        #expect(status.usage == .failed("接口限流"))
    }

    @Test func emptyWindowsMeansNoData() throws {
        guard case .status(let status) = try output(#"{"plan":"X","state":"active","usage":{"windows":[]}}"#) else {
            Issue.record("应当是订阅信息"); return
        }
        #expect(status.usage == .noData)
    }

    @Test func invalid() {
        expectError(field: nil) { _ = try output("") }
        expectError(field: nil) { _ = try output(#"["plan"]"#) }
        expectError(field: "error") { _ = try output(#"{"error":""}"#) }
        expectError(field: "error") { _ = try output(#"{"error":{"message":"x"}}"#) }
        expectError(field: "plan") { _ = try output(#"{"state":"active"}"#) }
        expectError(field: "plan") { _ = try output(#"{"plan":"","state":"active"}"#) }
        expectError(field: "planShortName") { _ = try output(#"{"plan":"X","planShortName":1,"state":"active"}"#) }
        expectError(field: "state") { _ = try output(#"{"plan":"X"}"#) }
        expectError(field: "state") { _ = try output(#"{"plan":"X","state":"paid"}"#) }
        expectError(field: "account") { _ = try output(#"{"plan":"X","state":"active","account":42}"#) }
        expectError(field: "periodEnd") { _ = try output(#"{"plan":"X","state":"active","periodEnd":"2026-12-01"}"#) }
        expectError(field: "periodEnd") { _ = try output(#"{"plan":"X","state":"active","periodEnd":1796000000}"#) }
    }

    @Test func invalidUsage() {
        func usage(_ json: String) throws {
            _ = try output(#"{"plan":"X","state":"active","usage":\#(json)}"#)
        }
        expectError(field: "usage") { try usage("[]") }
        expectError(field: "usage.windows") { try usage("{}") }
        expectError(field: "usage.unavailable") { try usage(#"{"unavailable":""}"#) }
        expectError(field: "usage.windows[0]") { try usage(#"{"windows":[1]}"#) }
        expectError(field: "usage.windows[0]") { try usage(#"{"windows":[{"usedPercent":1}]}"#) }
        expectError(field: "usage.windows[0].usedPercent") { try usage(#"{"windows":[{"label":"a"}]}"#) }
        expectError(field: "usage.windows[0].usedPercent") { try usage(#"{"windows":[{"label":"a","usedPercent":"5"}]}"#) }
        expectError(field: "usage.windows[0].usedPercent") { try usage(#"{"windows":[{"label":"a","usedPercent":true}]}"#) }
        expectError(field: "usage.windows[1].usedPercent") {
            try usage(#"{"windows":[{"label":"a","usedPercent":1},{"label":"b","usedPercent":-1}]}"#)
        }
        expectError(field: "usage.windows[0].windowMinutes") { try usage(#"{"windows":[{"windowMinutes":0,"usedPercent":1}]}"#) }
        expectError(field: "usage.windows[0].windowMinutes") { try usage(#"{"windows":[{"windowMinutes":1.5,"usedPercent":1}]}"#) }
        expectError(field: "usage.windows[0].label") { try usage(#"{"windows":[{"label":"","usedPercent":1}]}"#) }
        expectError(field: "usage.windows[0].resetsAt") { try usage(#"{"windows":[{"label":"a","usedPercent":1,"resetsAt":"tomorrow"}]}"#) }
        expectError(field: "usage.capturedAt") { try usage(#"{"windows":[],"capturedAt":"now"}"#) }
    }

    @Test func percentOver100IsAllowed() throws {
        // 超额使用时可能超过 100%
        guard case .status(let status) = try output(#"{"plan":"X","state":"active","usage":{"windows":[{"label":"a","usedPercent":120}]}}"#) else {
            Issue.record("应当是订阅信息"); return
        }
        #expect(status.usage.usage?.windows.first?.usedPercent == 120)
    }

    @Test func errorMessageNamesTheField() {
        do {
            _ = try output(#"{"plan":"X","state":"paid"}"#)
        } catch {
            #expect(error.message.hasPrefix("state："))
            #expect(error.message.contains("signedOut"))
        }
    }
}
