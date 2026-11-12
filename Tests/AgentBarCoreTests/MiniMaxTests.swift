import Foundation
import Testing
@testable import AgentBarCore

private let now = Date(timeIntervalSince1970: 1_794_490_000)  // 2026-11-12 21:26（北京时间）

private let quotaJSON = #"""
{"model_remains":[{"start_time":1794485932795,"end_time":1794503932795,"remains_time":17999994,
  "current_interval_total_count":0,"current_interval_usage_count":0,"model_name":"general",
  "current_weekly_total_count":0,"current_weekly_usage_count":0,
  "weekly_start_time":1794243376258,"weekly_end_time":1794848176258,"weekly_remains_time":362556143,
  "current_interval_status":1,"current_interval_remaining_percent":100,
  "current_weekly_status":1,"current_weekly_remaining_percent":38}],
 "base_resp":{"status_code":0,"status_msg":"success"}}
"""#

private let authJSON = #"{"method":"oauth","source":"config.json","token_expires":"2026-11-19T12:00:00.000Z"}"#

/// 记录调用次数、按参数返回预设输出的假命令行。
private final class FakeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var outputs: [String: Result<String, MmxError>]

    init(_ outputs: [String: Result<String, MmxError>]) { self.outputs = outputs }

    func run(_ arguments: [String]) async throws -> Data {
        lock.withLock { calls.append(arguments) }
        try await Task.sleep(for: .milliseconds(20))  // 让并发调用真正重叠
        let key = arguments.prefix(2).joined(separator: " ")
        return Data(try (outputs[key] ?? .failure(.notInstalled)).get().utf8)
    }

    func count(_ command: String) -> Int {
        lock.withLock { calls.filter { $0.prefix(2).joined(separator: " ") == command }.count }
    }
}

private func client(_ cli: FakeCLI) -> MmxClient {
    MmxClient(run: { try await cli.run($0) }, now: { now })
}

private func healthyCLI() -> FakeCLI {
    FakeCLI(["quota show": .success(quotaJSON), "auth status": .success(authJSON)])
}

@Suite struct MmxClientTests {
    @Test func parsesQuotaWindows() async throws {
        let usage = try #require(await client(healthyCLI()).quota().usage)

        #expect(usage.capturedAt == now)
        #expect(usage.source == "mmx")
        #expect(usage.windows == [
            UsageWindow(id: "interval", windowMinutes: 300, usedPercent: 0,
                        resetsAt: Date(timeIntervalSince1970: 1_794_503_932.795)),
            UsageWindow(id: "weekly", windowMinutes: 10080, usedPercent: 62,
                        resetsAt: Date(timeIntervalSince1970: 1_794_848_176.258)),
        ])
        #expect(usage.windows.map(\.name) == ["5 小时", "每周"])
    }

    @Test func passesJSONAndNonInteractiveFlags() async {
        let cli = healthyCLI()
        _ = await client(cli).quota()
        #expect(cli.calls.first == ["quota", "show", "--output", "json", "--non-interactive", "--no-color"])
    }

    @Test func unlimitedWindowsAreSkipped() async throws {
        let json = quotaJSON.replacingOccurrences(of: #""current_weekly_status":1"#, with: #""current_weekly_status":3"#)
        let cli = FakeCLI(["quota show": .success(json)])
        let usage = try #require(await client(cli).quota().usage)
        #expect(usage.windows.map(\.id) == ["interval"])
    }

    @Test func apiErrorIsReported() async {
        let json = #"{"model_remains":[],"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#
        let cli = FakeCLI(["quota show": .success(json)])
        #expect(await client(cli).quota() == .failed("mmx：login fail"))
    }

    @Test func emptyRemainsIsNoData() async {
        let json = #"{"model_remains":[],"base_resp":{"status_code":0,"status_msg":"success"}}"#
        #expect(await client(FakeCLI(["quota show": .success(json)])).quota() == .noData)
    }

    @Test func commandErrors() async {
        #expect(await client(FakeCLI([:])).quota() == .failed(MmxError.notInstalled.message))
        #expect(await client(FakeCLI(["quota show": .failure(.timedOut)])).quota()
            == .failed("mmx 响应超时"))
        #expect(await client(FakeCLI(["quota show": .success("not json")])).quota()
            == .failed("mmx 输出格式无法识别"))
    }

    @Test func concurrentCallsShareOneInvocationAndCache() async {
        let cli = healthyCLI()
        let shared = client(cli)
        async let a = shared.quota()
        async let b = shared.quota()
        _ = await (a, b)
        _ = await shared.quota()
        #expect(cli.count("quota show") == 1)
    }

    @Test func authStatus() async {
        #expect(await client(healthyCLI()).authStatus()
            == .signedIn(method: "oauth", tokenExpires: "2026-11-19T12:00:00.000Z"))

        let loggedOut = #"{"error":{"code":3,"message":"Not logged in. Run: mmx auth login"}}"#
        #expect(await client(FakeCLI(["auth status": .success(loggedOut)])).authStatus() == .signedOut)

        #expect(await client(FakeCLI([:])).authStatus() == .failed(MmxError.notInstalled.message))
    }
}

@Suite struct MmxProviderTests {
    func home(installed: Bool = true) throws -> TestHome {
        let home = try TestHome()
        if installed { try home.write("{}", to: ".mmx/config.json") }
        return home
    }

    @Test func installedWhenConfigExists() throws {
        #expect(MmxProvider(home: try home().url, client: client(healthyCLI())).isInstalled())
        #expect(!MmxProvider(home: try home(installed: false).url, client: client(healthyCLI())).isInstalled())
    }

    @Test func signedInWithUsage() async throws {
        let status = try await MmxProvider(home: try home().url, client: client(healthyCLI())).fetchStatus()

        #expect(status.plan == Plan(rawValue: "oauth", displayName: "Token Plan"))
        #expect(status.state == .active)
        #expect(status.usage.usage?.windows.count == 2)
        #expect(status.usage.usage?.source == nil)  // 自己的数据，不注明来源
        #expect(status.details == [Detail("method", "oauth"), Detail("token_expires", "2026-11-19T12:00:00.000Z")])
    }

    @Test func usageDisabledDoesNotRunQuota() async throws {
        let cli = healthyCLI()
        let status = try await MmxProvider(home: try home().url, client: client(cli), fetchesUsage: false).fetchStatus()
        #expect(status.usage == .networkDisabled)
        #expect(cli.count("quota show") == 0)
    }

    @Test func signedOut() async throws {
        let cli = FakeCLI(["auth status": .success(#"{"error":{"message":"Not logged in"}}"#)])
        let status = try await MmxProvider(home: try home().url, client: client(cli)).fetchStatus()
        #expect(status.state == .signedOut)
        #expect(cli.count("quota show") == 0)
    }

    @Test func authFailureThrows() async throws {
        let provider = MmxProvider(home: try home().url, client: client(FakeCLI(["auth status": .failure(.timedOut)])))
        await #expect(throws: ProviderError.unreadable("mmx 响应超时")) { try await provider.fetchStatus() }
    }

    @Test func identity() throws {
        let provider = MmxProvider(home: try home().url, client: client(healthyCLI()))
        #expect(provider.id == "mmx")
        #expect(provider.displayName == "mmx")
        #expect(provider.iconName == "minimax")
    }
}

@Suite struct MiniMaxCodeProviderTests {
    func home(authState: String?, region: String = "en", configYAML: Bool = true) throws -> TestHome {
        let home = try TestHome()
        if configYAML { try home.write("logLevel: info\n", to: ".minimax/config.yaml") }
        if let authState {
            try home.write(authState, to: ".minimax/auth/prod/\(region)/mcode-public/auth-state.json")
        }
        return home
    }

    let authenticated = #"{"schemaVersion":2,"status":"authenticated","storeKind":"file","region":"en","expiresAtMs":1794432740000}"#

    fileprivate func provider(_ home: TestHome, cli: FakeCLI? = nil, mmxInstalled: Bool = true, appInstalled: Bool = false) -> MiniMaxCodeProvider {
        MiniMaxCodeProvider(
            home: home.url,
            appURL: home.path(appInstalled ? "" : "Applications/missing.app"),
            mmx: client(cli ?? healthyCLI()),
            mmxInstalled: { mmxInstalled })
    }

    @Test func installedByConfigOrApp() throws {
        #expect(provider(try home(authState: nil)).isInstalled())
        #expect(!provider(try home(authState: nil, configYAML: false)).isInstalled())
        #expect(provider(try home(authState: nil, configYAML: false), appInstalled: true).isInstalled())
    }

    @Test func signedInWithUsageFromMmx() async throws {
        let status = try await provider(try home(authState: authenticated)).fetchStatus()

        #expect(status.state == .active)
        #expect(status.plan.displayName == "已登录")
        #expect(status.details == [Detail("region", "en")])
        #expect(status.usage.usage?.source == "mmx")
        #expect(status.usage.usage?.windows.map(\.name) == ["5 小时", "每周"])
    }

    @Test func otherRegionDirectory() async throws {
        let state = authenticated.replacingOccurrences(of: #""region":"en""#, with: #""region":"cn""#)
        let status = try await provider(try home(authState: state, region: "cn")).fetchStatus()
        #expect(status.state == .active)
        #expect(status.details == [Detail("region", "cn")])
    }

    @Test func notAuthenticated() async throws {
        let state = authenticated.replacingOccurrences(of: "authenticated", with: "signed_out")
        let cli = healthyCLI()
        let status = try await provider(try home(authState: state), cli: cli).fetchStatus()
        #expect(status.state == .signedOut)
        #expect(cli.count("quota show") == 0)
    }

    @Test func noAuthStateIsSignedOut() async throws {
        #expect(try await provider(try home(authState: nil)).fetchStatus().state == .signedOut)
    }

    @Test func withoutMmxUsageIsUnsupported() async throws {
        let status = try await provider(try home(authState: authenticated), mmxInstalled: false).fetchStatus()
        #expect(status.usage == .unsupported)
    }

    @Test func usageDisabled() async throws {
        let home = try home(authState: authenticated)
        let provider = MiniMaxCodeProvider(
            home: home.url, appURL: home.path("x.app"), mmx: client(healthyCLI()),
            mmxInstalled: { true }, fetchesUsage: false)
        #expect(try await provider.fetchStatus().usage == .networkDisabled)
    }

    @Test func identity() throws {
        let provider = provider(try home(authState: nil))
        #expect(provider.id == "minimax-code")
        #expect(provider.displayName == "MiniMax Code")
        #expect(provider.iconName == "minimax")
    }
}

@Suite struct MiniMaxSettingsTests {
    @Test func mmxUsageDefaultsOn() throws {
        #expect(AppSettings().minimaxUsageViaMmx == true)
        var settings = AppSettings()
        settings.minimaxUsageViaMmx = false
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func registryIncludesMiniMaxProviders() {
        let ids = ProviderRegistry.standard.providers.map(\.id)
        #expect(ids == ["claude-code", "codex", "cursor", "minimax-code", "mmx"])
    }
}
