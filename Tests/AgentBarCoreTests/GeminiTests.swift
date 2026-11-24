import Foundation
import Testing
@testable import AgentBarCore

private let now = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18 16:26（北京时间）
private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

/// 结构与 Gemini CLI 开源代码一致（packages/core/src/code_assist/types.ts）。
private let loadResponse = #"""
{"currentTier":{"id":"standard-tier","name":"Gemini Code Assist"},
 "paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"},
 "cloudaicompanionProject":"robust-cloud-123"}
"""#
private let quotaResponse = #"""
{"buckets":[
  {"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.75,"resetTime":"2026-11-19T00:00:00Z"},
  {"modelId":"gemini-2.5-flash","tokenType":"REQUESTS","remainingFraction":1},
  {"modelId":"gemini-2.5-flash-lite","tokenType":"REQUESTS"}
]}
"""#

private func home(settings: String? = nil, accounts: String? = nil, creds: String? = nil) throws -> TestHome {
    let home = try TestHome()
    if let settings { try home.write(settings, to: ".gemini/settings.json") }
    if let accounts { try home.write(accounts, to: ".gemini/google_accounts.json") }
    if let creds { try home.write(creds, to: ".gemini/oauth_creds.json") }
    return home
}

private func creds(expiresAt: Date, refreshToken: String? = "refresh-abc") -> String {
    let refresh = refreshToken.map { #","refresh_token":"\#($0)""# } ?? ""
    return #"{"access_token":"file-token","token_type":"Bearer","expiry_date":\#(ms(expiresAt))\#(refresh)}"#
}

/// 按 URL 路径返回预设响应，并记录请求。
private final class FakeGoogle: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var responses: [String: [(Int, String)]]

    init(_ responses: [String: [(Int, String)]]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = request.url!.absoluteString
        let (status, body) = try lock.withLock { () throws -> (Int, String) in
            requests.append(request)
            guard var queue = responses[key], !queue.isEmpty else { throw URLError(.cannotConnectToHost) }
            let first = queue.removeFirst()
            if !queue.isEmpty { responses[key] = queue }
            return first
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func calls(_ suffix: String) -> [URLRequest] {
        lock.withLock { requests.filter { $0.url!.absoluteString.hasSuffix(suffix) } }
    }
}

private let loadURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
private let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
private let tokenURL = "https://oauth2.googleapis.com/token"

/// 假的 OAuth 客户端信息（拼接生成，避免被当成真实密钥）。
private let fakeSecret = "GOCSPX" + "-" + String(repeating: "x", count: 28)
private let fakeClientID = "123456789012-" + String(repeating: "a", count: 32) + ".apps.googleusercontent.com"
private let fakeClient = GeminiOAuthClient(id: fakeClientID, secret: fakeSecret)

private func fetcher(_ home: TestHome, _ google: FakeGoogle, client: GeminiOAuthClient? = fakeClient) -> GeminiUsageFetcher {
    GeminiUsageFetcher(home: home.url, send: { try await google.send($0) }, locateClient: { client }, now: { now })
}

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

@Suite struct GeminiProviderTests {
    @Test func installation() throws {
        #expect(!GeminiCLIProvider(home: try home().url).isInstalled())

        // Antigravity 也会创建 ~/.gemini/，只有它的子目录时不算安装了 Gemini CLI
        let antigravity = try home()
        try antigravity.write("{}", to: ".gemini/antigravity/state.json")
        #expect(!GeminiCLIProvider(home: antigravity.url).isInstalled())

        #expect(GeminiCLIProvider(home: try home(accounts: #"{"active":null,"old":[]}"#).url).isInstalled())
        #expect(GeminiCLIProvider(home: try home(settings: "{}").url).isInstalled())
        #expect(GeminiCLIProvider(home: try home(creds: "{}").url).isInstalled())
    }

    @Test func googleLoginWithoutNetwork() async throws {
        // settings.json 允许注释和末尾逗号
        let home = try home(
            settings: """
            {
              // 登录方式
              "security": { "auth": { "selectedType": "oauth-personal", }, },
            }
            """,
            accounts: #"{"active":"gemini-user@example.com","old":[]}"#,
            creds: creds(expiresAt: now))
        let status = try await GeminiCLIProvider(home: home.url).fetchStatus()

        #expect(status.plan == Plan(rawValue: "oauth-personal", displayName: "Google 账号"))
        #expect(status.state == .active)
        #expect(status.account == "gemini-user@example.com")
        #expect(status.usage == .networkDisabled)
    }

    @Test func defaultsToGoogleLoginWhenCredentialsExist() async throws {
        let status = try await GeminiCLIProvider(home: try home(creds: creds(expiresAt: now)).url).fetchStatus()
        #expect(status.plan.displayName == "Google 账号")
        #expect(status.state == .active)
    }

    @Test func legacySettingKey() async throws {
        let home = try home(settings: #"{"selectedAuthType":"gemini-api-key"}"#)
        let status = try await GeminiCLIProvider(home: home.url).fetchStatus()
        #expect(status.plan.displayName == "API key")
    }

    @Test(arguments: [
        ("gemini-api-key", "API key"),
        ("vertex-ai", "Vertex AI"),
        ("compute-default-credentials", "Google Cloud 凭据"),
        ("cloud-shell", "Cloud Shell"),
        ("something-new", "something-new"),
    ])
    func otherAuthTypes(raw: String, name: String) async throws {
        let home = try home(settings: #"{"security":{"auth":{"selectedType":"\#(raw)"}}}"#)
        let status = try await GeminiCLIProvider(home: home.url).fetchStatus()
        #expect(status.plan.displayName == name)
        #expect(status.state == .active)
        // 这些方式没有订阅和额度可查
        #expect(status.usage == .unsupported)
    }

    @Test func signedOut() async throws {
        let home = try home(settings: #"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#,
                            accounts: #"{"active":null,"old":["old@example.com"]}"#)
        let status = try await GeminiCLIProvider(home: home.url).fetchStatus()
        #expect(status.state == .signedOut)
        #expect(status.account == nil)
    }

    @Test func unreadableSettingsFallBackToCredentials() async throws {
        let home = try home(settings: "not json at all", creds: creds(expiresAt: now))
        #expect(try await GeminiCLIProvider(home: home.url).fetchStatus().plan.displayName == "Google 账号")
    }

    @Test func onlineReplacesPlanAndAddsUsage() async throws {
        let home = try home(accounts: #"{"active":"gemini-user@example.com"}"#,
                            creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([loadURL: [(200, loadResponse)], quotaURL: [(200, quotaResponse)]])
        let provider = GeminiCLIProvider(home: home.url, usageFetcher: fetcher(home, google))

        let status = try await provider.fetchStatus()

        #expect(status.plan == Plan(rawValue: "g1-pro-tier", displayName: "Google AI Pro"))
        #expect(status.account == "gemini-user@example.com")
        #expect(status.usage.usage?.windows == [
            UsageWindow(id: "gemini-2.5-pro", windowMinutes: nil, usedPercent: 25,
                        resetsAt: DateParsing.iso8601("2026-11-19T00:00:00Z"), label: "gemini-2.5-pro"),
            UsageWindow(id: "gemini-2.5-flash", windowMinutes: nil, usedPercent: 0, resetsAt: nil, label: "gemini-2.5-flash"),
        ])
        #expect(status.usage.usage?.capturedAt == now)
    }

    @Test func onlineFailureKeepsLocalInfo() async throws {
        let home = try home(accounts: #"{"active":"gemini-user@example.com"}"#,
                            creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([loadURL: [(500, "{}")]])
        let status = try await GeminiCLIProvider(home: home.url, usageFetcher: fetcher(home, google)).fetchStatus()

        #expect(status.plan.displayName == "Google 账号")
        #expect(status.usage == .failed("接口返回 500"))
    }

    @Test func apiKeyNeverGoesOnline() async throws {
        let home = try home(settings: #"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#,
                            creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([:])
        _ = try await GeminiCLIProvider(home: home.url, usageFetcher: fetcher(home, google)).fetchStatus()
        #expect(google.requests.isEmpty)
    }
}

@Suite struct GeminiUsageFetcherTests {
    @Test func usesValidTokenFromFile() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([loadURL: [(200, loadResponse)], quotaURL: [(200, quotaResponse)]])

        let result = try await fetcher(home, google).fetch().get()

        #expect(result.plan.displayName == "Google AI Pro")
        #expect(google.calls("token").isEmpty)
        let load = try #require(google.calls("loadCodeAssist").first)
        #expect(load.value(forHTTPHeaderField: "Authorization") == "Bearer file-token")
        #expect(load.httpMethod == "POST")
        #expect((body(load)["metadata"] as? [String: String])?["pluginType"] == "GEMINI")
        let quota = try #require(google.calls("retrieveUserQuota").first)
        #expect(body(quota)["project"] as? String == "robust-cloud-123")
    }

    @Test func refreshesExpiredTokenInMemoryOnly() async throws {
        let original = creds(expiresAt: now.addingTimeInterval(30))  // 不到 1 分钟就过期，按已过期处理
        let home = try home(creds: original)
        let google = FakeGoogle([
            tokenURL: [(200, #"{"access_token":"fresh-token","expires_in":3599,"token_type":"Bearer"}"#)],
            loadURL: [(200, loadResponse), (200, loadResponse)],
            quotaURL: [(200, quotaResponse), (200, quotaResponse)],
        ])
        let fetcher = fetcher(home, google)

        _ = try await fetcher.fetch().get()
        _ = try await fetcher.fetch().get()

        let refresh = try #require(google.calls("token").first)
        #expect(google.calls("token").count == 1)  // 第二次用内存里缓存的 token
        let form = String(decoding: refresh.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=refresh-abc"))
        #expect(form.contains("client_id=123456789012-"))
        #expect(form.contains("client_secret=GOCSPX-xxx"))
        #expect(refresh.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(google.calls("loadCodeAssist").allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token" })
        // 不写回 Gemini CLI 的凭据文件
        #expect(try String(contentsOf: home.path(".gemini/oauth_creds.json"), encoding: .utf8) == original)
    }

    @Test func retriesOnceWithRefreshedTokenAfter401() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([
            loadURL: [(401, "{}"), (200, loadResponse)],
            tokenURL: [(200, #"{"access_token":"fresh-token","expires_in":3599}"#)],
            quotaURL: [(200, quotaResponse)],
        ])
        let result = try await fetcher(home, google).fetch().get()
        #expect(result.plan.displayName == "Google AI Pro")
        #expect(google.calls("loadCodeAssist").last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test func refreshRejected() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(-60)))
        let google = FakeGoogle([tokenURL: [(400, #"{"error":"invalid_grant"}"#)]])
        #expect(await fetcher(home, google).fetch() == .failure(.refreshRejected))
        #expect(GeminiUsageError.refreshRejected.message.contains("gemini"))
    }

    @Test func expiredWithoutLocalGeminiCLICannotRefresh() async throws {
        let valid = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let expired = try home(creds: creds(expiresAt: now.addingTimeInterval(-60)))
        let google = FakeGoogle([:])
        #expect(await fetcher(expired, google, client: nil).fetch() == .failure(.cannotRefresh))
        #expect(google.requests.isEmpty)

        // token 还有效时不需要客户端信息
        let ok = FakeGoogle([loadURL: [(200, loadResponse)], quotaURL: [(200, quotaResponse)]])
        #expect(try await fetcher(valid, ok, client: nil).fetch().get().plan.displayName == "Google AI Pro")
    }

    @Test func notSignedIn() async throws {
        #expect(await fetcher(try home(), FakeGoogle([:])).fetch() == .failure(.notSignedIn))
        // 过期且没有 refresh token
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(-60), refreshToken: nil))
        #expect(await fetcher(home, FakeGoogle([:])).fetch() == .failure(.notSignedIn))
    }

    @Test func withoutProjectThereIsNoQuota() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([loadURL: [(200, #"{"currentTier":{"id":"free-tier","name":""}}"#)]])
        let result = try await fetcher(home, google).fetch().get()
        #expect(result.plan == Plan(rawValue: "free-tier", displayName: "Free"))
        #expect(result.usage == .failed("没有可用的 Google Cloud 项目"))
        #expect(google.calls("retrieveUserQuota").isEmpty)
    }

    @Test func quotaFailureStillReturnsPlan() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let google = FakeGoogle([loadURL: [(200, loadResponse)], quotaURL: [(503, "{}")]])
        let result = try await fetcher(home, google).fetch().get()
        #expect(result.plan.displayName == "Google AI Pro")
        #expect(result.usage == .failed("接口返回 503"))
    }

    @Test func duplicateModelsAreLabelledByTokenType() async throws {
        let home = try home(creds: creds(expiresAt: now.addingTimeInterval(3600)))
        let quota = #"{"buckets":[{"modelId":"m","tokenType":"REQUESTS","remainingFraction":0.5},{"modelId":"m","tokenType":"TOKENS","remainingFraction":0.9}]}"#
        let google = FakeGoogle([loadURL: [(200, loadResponse)], quotaURL: [(200, quota)]])
        let windows = try await fetcher(home, google).fetch().get().usage.usage?.windows
        #expect(windows?.map(\.name) == ["m · REQUESTS", "m · TOKENS"])
        #expect(Set(windows?.map(\.id) ?? []).count == 2)
    }

    @Test(arguments: [
        ("free-tier", "", "Free"), ("standard-tier", nil, "Standard"), ("legacy-tier", nil, "Legacy"),
        ("x-tier", nil, "x-tier"),
    ] as [(String, String?, String)])
    func tierNames(id: String, name: String?, expected: String) {
        #expect(GeminiUsageFetcher.plan(id: id, name: name).displayName == expected)
    }
}

@Suite struct GeminiOAuthClientTests {
    private func package(in home: TestHome, at path: String, name: String = "@google/gemini-cli") throws {
        try home.write(#"{"name":"\#(name)","version":"0.20.0"}"#, to: "\(path)/package.json")
    }

    private func source(id: String = fakeClientID, secret: String = fakeSecret) -> String {
        "const OAUTH_CLIENT_ID =\n  '\(id)';\nconst OAUTH_CLIENT_SECRET = '\(secret)';\n"
    }

    @Test func findsBundledClient() throws {
        let home = try TestHome()
        let root = ".npm-global/lib/node_modules/@google/gemini-cli"
        try package(in: home, at: root)
        try home.write("// 其他代码\n" + source(), to: "\(root)/bundle/gemini.js")

        #expect(GeminiOAuthClient.locate(home: home.url) == fakeClient)
    }

    @Test func findsClientInCorePackage() throws {
        let home = try TestHome()
        let root = ".local/share/mise/installs/node/22.11.0/lib/node_modules/@google/gemini-cli"
        try package(in: home, at: root)
        try home.write(source(), to: "\(root)/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")

        #expect(GeminiOAuthClient.locate(home: home.url) == fakeClient)
    }

    @Test func fallsBackToScanningJSFiles() throws {
        let home = try TestHome()
        let root = ".nvm/versions/node/v22.0.0/lib/node_modules/@google/gemini-cli"
        try package(in: home, at: root)
        try home.write("console.log(1)", to: "\(root)/dist/index.js")
        try home.write(source(), to: "\(root)/dist/src/chunk-abc123.js")

        #expect(GeminiOAuthClient.locate(home: home.url) == fakeClient)
    }

    @Test func requiresBothValuesInTheSameFile() throws {
        let home = try TestHome()
        let root = ".npm-global/lib/node_modules/@google/gemini-cli"
        try package(in: home, at: root)
        try home.write("'\(fakeClientID)'", to: "\(root)/bundle/gemini.js")
        try home.write("'\(fakeSecret)'", to: "\(root)/dist/other.js")

        #expect(GeminiOAuthClient.locate(home: home.url) == nil)
    }

    @Test func ignoresOtherPackages() throws {
        let home = try TestHome()
        let root = ".npm-global/lib/node_modules/@google/gemini-cli"
        try package(in: home, at: root, name: "something-else")
        try home.write(source(), to: "\(root)/bundle/gemini.js")

        #expect(GeminiOAuthClient.locate(home: home.url) == nil)
        #expect(GeminiOAuthClient.locate(home: try TestHome().url) == nil)
    }
}
