import Foundation
import SQLite3
import Testing
@testable import AgentBarCore

private let now = Date(timeIntervalSince1970: 1_794_470_000)  // 2026-11-12

/// 测试用 JWT（签名是假的）。
private func makeJWT(exp: Date) -> String {
    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = base64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
    let payload = base64url(Data(#"{"sub":"user_1","exp":\#(Int(exp.timeIntervalSince1970))}"#.utf8))
    return "\(header).\(payload).fake-signature"
}

private let validToken = makeJWT(exp: now.addingTimeInterval(3600))

private let usageJSON = #"""
{"billingCycleStart":"1793242633000","billingCycleEnd":"1795921033000",
 "planUsage":{"totalSpend":31429,"includedSpend":7000,"bonusSpend":24429,"limit":7000,"remainingBonus":false,
   "autoPercentUsed":26.182499999999997,"apiPercentUsed":0.09090909090909091,"totalPercentUsed":23.991603053435114},
 "spendLimitUsage":{"limitType":"user"},"displayThreshold":200,"enabled":true}
"""#

/// 记录请求、按预设返回的假网络层。
private final class FakeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var response: Result<(Int, Data), Error>

    init(_ response: Result<(Int, Data), Error>) { self.response = response }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let (status, data) = try response.get()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// 计数的假钥匙串。
private final class FakeTokenSource: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reads = 0
    var result: Result<String, CursorUsageError>

    init(_ result: Result<String, CursorUsageError>) { self.result = result }

    func read() throws -> String {
        lock.withLock { reads += 1 }
        return try result.get()
    }
}

private func makeFetcher(
    token: FakeTokenSource = FakeTokenSource(.success(validToken)),
    transport: FakeTransport = FakeTransport(.success((200, Data(usageJSON.utf8)))),
    clock: @escaping @Sendable () -> Date = { now }
) -> CursorUsageFetcher {
    CursorUsageFetcher(
        readToken: { try token.read() },
        send: { try await transport.send($0) },
        clientVersion: { "2026.11.11-043ef28" },
        now: clock)
}

@Suite struct CursorUsageFetcherTests {
    @Test func parsesUsageAndBillingCycle() async throws {
        let result = try await makeFetcher().fetch()

        let end = Date(timeIntervalSince1970: 1_795_921_033)
        #expect(result.billingCycleEnd == end)
        #expect(result.usage.capturedAt == now)
        #expect(result.usage.windows == [
            UsageWindow(id: "total", windowMinutes: nil, usedPercent: 23.991603053435114, resetsAt: end, label: "本计费周期"),
            UsageWindow(id: "auto", windowMinutes: nil, usedPercent: 26.182499999999997, resetsAt: end, label: "Auto"),
            UsageWindow(id: "api", windowMinutes: nil, usedPercent: 0.09090909090909091, resetsAt: end, label: "API"),
        ])
    }

    @Test func sendsCLIRequest() async throws {
        let transport = FakeTransport(.success((200, Data(usageJSON.utf8))))
        _ = try await makeFetcher(transport: transport).fetch()

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url?.absoluteString
            == "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validToken)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-type") == "cli")
        #expect(request.value(forHTTPHeaderField: "x-cursor-client-version") == "2026.11.11-043ef28")
        #expect(request.value(forHTTPHeaderField: "x-ghost-mode") == "true")
    }

    @Test func notSignedIn() async {
        let fetcher = makeFetcher(token: FakeTokenSource(.failure(.notSignedIn)))
        await #expect(throws: CursorUsageError.notSignedIn) { try await fetcher.fetch() }
        #expect(CursorUsageError.notSignedIn.message == "没有找到 cursor-agent 的登录，请安装并运行 cursor-agent login")
    }

    @Test func expiredTokenIsNotSent() async {
        let transport = FakeTransport(.success((200, Data(usageJSON.utf8))))
        let token = FakeTokenSource(.success(makeJWT(exp: now.addingTimeInterval(-60))))
        let fetcher = makeFetcher(token: token, transport: transport)

        await #expect(throws: CursorUsageError.tokenExpired) { try await fetcher.fetch() }
        #expect(transport.requests.isEmpty)
    }

    @Test func keychainDenialIsRememberedFor30Minutes() async {
        let token = FakeTokenSource(.failure(.keychainDenied))
        let clock = TestClock(now)
        let fetcher = makeFetcher(token: token, clock: { clock.now })

        await #expect(throws: CursorUsageError.keychainDenied) { try await fetcher.fetch() }
        clock.advance(by: 29 * 60)
        await #expect(throws: CursorUsageError.keychainDenied) { try await fetcher.fetch() }
        #expect(token.reads == 1)

        clock.advance(by: 2 * 60)
        token.result = .success(validToken)
        _ = try? await fetcher.fetch()
        #expect(token.reads == 2)
    }

    @Test func unauthorized() async {
        let fetcher = makeFetcher(transport: FakeTransport(.success((401, Data(#"{"code":"unauthenticated"}"#.utf8)))))
        await #expect(throws: CursorUsageError.unauthorized) { try await fetcher.fetch() }
    }

    @Test func otherHTTPError() async {
        let fetcher = makeFetcher(transport: FakeTransport(.success((503, Data()))))
        await #expect(throws: CursorUsageError.http(503)) { try await fetcher.fetch() }
        #expect(CursorUsageError.http(503).message == "接口返回 503")
    }

    @Test func timeout() async {
        let fetcher = makeFetcher(transport: FakeTransport(.failure(URLError(.timedOut))))
        await #expect(throws: CursorUsageError.timedOut) { try await fetcher.fetch() }
    }

    @Test func unexpectedFormat() async {
        for body in ["not json", #"{"billingCycleEnd":"1795921033000"}"#] {
            let fetcher = makeFetcher(transport: FakeTransport(.success((200, Data(body.utf8)))))
            await #expect(throws: CursorUsageError.unexpectedFormat) { try await fetcher.fetch() }
        }
    }

    @Test func numericBillingCycleIsAccepted() async throws {
        let body = #"{"billingCycleEnd":1795921033000,"planUsage":{"totalPercentUsed":5}}"#
        let fetcher = makeFetcher(transport: FakeTransport(.success((200, Data(body.utf8)))))
        let result = try await fetcher.fetch()
        #expect(result.billingCycleEnd == Date(timeIntervalSince1970: 1_795_921_033))
        #expect(result.usage.windows.map(\.id) == ["total"])
    }
}

/// 可手动拨动的时钟。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

// MARK: - CursorProvider 集成

private func cursorHome(_ items: [String: String]) throws -> TestHome {
    let home = try TestHome()
    let url = home.path("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(url.path, &db)
    sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil)
    for (key, value) in items {
        sqlite3_exec(db, "INSERT INTO ItemTable VALUES ('\(key)', '\(value)')", nil, nil, nil)
    }
    sqlite3_close(db)
    return home
}

private let signedIn = [
    "cursorAuth/stripeMembershipType": "pro_plus",
    "cursorAuth/stripeSubscriptionStatus": "active",
    "cursorAuth/cachedEmail": "cursor-user@example.com",
]

@Suite struct CursorProviderUsageTests {
    @Test func onlineUsageDisabled() async throws {
        let status = try await CursorProvider(home: try cursorHome(signedIn).url).fetchStatus()
        #expect(status.usage == .networkDisabled)
        #expect(status.periodEnd == nil)
    }

    @Test func onlineUsageEnabled() async throws {
        let provider = CursorProvider(home: try cursorHome(signedIn).url, usageFetcher: makeFetcher())
        let status = try await provider.fetchStatus()

        #expect(status.usage.usage?.windows.first?.usedPercent == 23.991603053435114)
        #expect(status.periodEnd == Date(timeIntervalSince1970: 1_795_921_033))
        #expect(status.plan.displayName == "Pro+")
    }

    @Test func onlineUsageFailureOnlyAffectsUsage() async throws {
        let fetcher = makeFetcher(transport: FakeTransport(.success((401, Data()))))
        let status = try await CursorProvider(home: try cursorHome(signedIn).url, usageFetcher: fetcher).fetchStatus()

        #expect(status.usage == .failed(CursorUsageError.unauthorized.message))
        #expect(status.plan.displayName == "Pro+")
        #expect(status.state == .active)
    }

    @Test func signedOutDoesNotFetch() async throws {
        let transport = FakeTransport(.success((200, Data(usageJSON.utf8))))
        let provider = CursorProvider(home: try cursorHome([:]).url, usageFetcher: makeFetcher(transport: transport))
        let status = try await provider.fetchStatus()

        #expect(status.usage == .unsupported)
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct OnlineUsageSettingsTests {
    @Test func defaultsToOff() {
        #expect(AppSettings().onlineUsageProviderIDs.isEmpty)
    }

    @Test func roundTrips() throws {
        var settings = AppSettings()
        settings.onlineUsageProviderIDs = ["cursor"]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func registryWiresFetcherOnlyWhenEnabled() {
        var settings = AppSettings()
        let fetcher = makeFetcher()
        #expect(ProviderRegistry.standard(settings: settings, cursorUsage: fetcher).cursorFetchesUsage == false)
        settings.onlineUsageProviderIDs = ["cursor"]
        #expect(ProviderRegistry.standard(settings: settings, cursorUsage: fetcher).cursorFetchesUsage == true)
    }
}

extension ProviderRegistry {
    /// 测试用：注册表里的 Cursor provider 是否带了用量获取器。
    var cursorFetchesUsage: Bool {
        providers.compactMap { $0 as? CursorProvider }.first?.fetchesUsage ?? false
    }
}
