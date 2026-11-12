import Foundation
import Testing
@testable import AgentBarCore

/// 生成测试用的 JWT（签名是假的，provider 不校验签名）。
private func makeJWT(_ payload: [String: Any]) throws -> String {
    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
    let body = try JSONSerialization.data(withJSONObject: payload)
    return "\(base64url(header)).\(base64url(body)).fake-signature"
}

private func chatGPTPayload(
    plan: String? = "plus",
    activeUntil: String? = "2026-11-22T08:06:34+00:00",
    lastChecked: String? = "2026-11-11T07:28:41.229263+00:00"
) -> [String: Any] {
    var auth: [String: Any] = ["chatgpt_account_id": "acct-fake"]
    auth["chatgpt_plan_type"] = plan
    auth["chatgpt_subscription_active_start"] = "2026-10-22T08:06:34+00:00"
    auth["chatgpt_subscription_active_until"] = activeUntil
    auth["chatgpt_subscription_last_checked"] = lastChecked
    return ["email": "codex-user@example.com", "https://api.openai.com/auth": auth]
}

/// 生成 `.codex/auth.json`。`idToken` 为 nil 时不写 tokens。
private func makeHome(authMode: String?, idToken: String?, apiKey: String? = nil) throws -> TestHome {
    var json: [String: Any] = ["OPENAI_API_KEY": apiKey ?? NSNull(), "last_refresh": "2026-11-11T07:28:41Z"]
    json["auth_mode"] = authMode
    if let idToken {
        json["tokens"] = [
            "id_token": idToken,
            "access_token": "fake-access-token",
            "refresh_token": "fake-refresh-token",
            "account_id": "acct-fake",
        ]
    }
    let home = try TestHome()
    try home.write(try JSONSerialization.data(withJSONObject: json), to: ".codex/auth.json")
    return home
}

private func date(_ iso: String) -> Date { DateParsing.iso8601(iso)! }

@Suite struct CodexProviderTests {
    let now = date("2026-11-11T00:00:00Z")

    func provider(_ home: TestHome, now: Date? = nil) -> CodexProvider {
        let now = now ?? self.now
        return CodexProvider(home: home.url, now: { now })
    }

    @Test func plusActive() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(chatGPTPayload()))
        let status = try await provider(home).fetchStatus()

        #expect(status.plan == Plan(rawValue: "plus", displayName: "ChatGPT Plus", shortName: "Plus"))
        #expect(status.state == .active)
        #expect(status.account == "codex-user@example.com")
        #expect(status.periodEnd == date("2026-11-22T08:06:34Z"))
        #expect(status.sourceUpdatedAt == date("2026-11-11T07:28:41.229Z"))
        #expect(status.details.contains(Detail("auth_mode", "chatgpt")))
    }

    @Test func subscriptionInThePastIsExpired() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(chatGPTPayload()))
        let status = try await provider(home, now: date("2026-12-01T00:00:00Z")).fetchStatus()

        #expect(status.state == .expired)
        #expect(status.periodEnd == date("2026-11-22T08:06:34Z"))
    }

    @Test func apiKeyModeDoesNotReadTokens() async throws {
        // id_token 故意是坏的：API key 模式下不应该去解析它。
        let home = try makeHome(authMode: "apikey", idToken: "not-a-jwt", apiKey: "sk-fake")
        let status = try await provider(home).fetchStatus()

        #expect(status.plan.displayName == "API key")
        #expect(status.state == .active)
        #expect(status.account == nil)
    }

    @Test func malformedJWTThrowsReadableError() async throws {
        for token in ["not-a-jwt", "a.!!!.c", "a.\(Data("not json".utf8).base64EncodedString()).c"] {
            let home = try makeHome(authMode: "chatgpt", idToken: token)
            await #expect(throws: ProviderError.unreadable("~/.codex/auth.json 中的 id_token 无法解析")) {
                try await provider(home).fetchStatus()
            }
        }
    }

    @Test func unknownPlanIsShownRaw() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(chatGPTPayload(plan: "galaxy")))
        let status = try await provider(home).fetchStatus()

        #expect(status.plan == Plan(rawValue: "galaxy", displayName: "galaxy"))
        #expect(status.state == .active)
    }

    @Test func missingSubscriptionFields() async throws {
        let payload = chatGPTPayload(plan: nil, activeUntil: nil, lastChecked: nil)
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(payload))
        let status = try await provider(home).fetchStatus()

        #expect(status.plan.displayName == "未知套餐")
        #expect(status.state == .unknown)
        #expect(status.periodEnd == nil)
        #expect(status.sourceUpdatedAt == nil)
        #expect(status.account == "codex-user@example.com")
    }

    @Test func missingAuthClaimEntirely() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(["email": "x@example.com"]))
        let status = try await provider(home).fetchStatus()

        #expect(status.state == .unknown)
        #expect(status.account == "x@example.com")
    }

    @Test func freePlanWithoutExpiryIsActive() async throws {
        let payload = chatGPTPayload(plan: "free", activeUntil: nil)
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(payload))
        let status = try await provider(home).fetchStatus()

        #expect(status.plan.displayName == "ChatGPT Free")
        #expect(status.state == .active)
    }

    @Test func legacyFileWithoutAuthModeButWithTokensIsChatGPT() async throws {
        let home = try makeHome(authMode: nil, idToken: try makeJWT(chatGPTPayload()))
        let status = try await provider(home).fetchStatus()

        #expect(status.plan.displayName == "ChatGPT Plus")
    }

    @Test func noTokensAndNoKeyIsSignedOut() async throws {
        let home = try makeHome(authMode: nil, idToken: nil)
        let status = try await provider(home).fetchStatus()

        #expect(status.state == .signedOut)
    }

    @Test func missingFileIsNotInstalled() async throws {
        let provider = CodexProvider(home: try TestHome().url)
        #expect(!provider.isInstalled())
        await #expect(throws: ProviderError.fileNotFound("~/.codex/auth.json")) {
            try await provider.fetchStatus()
        }
    }

    @Test func chatGPTLoginIncludesUsageFromSessionLogs() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(chatGPTPayload()))
        let line = #"{"timestamp":"2026-11-10T02:43:43.837Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1794296603},"secondary":{"used_percent":26.0,"window_minutes":10080,"resets_at":1794385798}}}}"#
        try home.write(line + "\n", to: ".codex/sessions/2026/11/09/rollout-x.jsonl")

        let status = try await provider(home).fetchStatus()

        #expect(status.usage.usage?.windows.map(\.usedPercent) == [12, 26])
    }

    @Test func chatGPTLoginWithoutSessionLogsHasNoUsageData() async throws {
        let home = try makeHome(authMode: "chatgpt", idToken: try makeJWT(chatGPTPayload()))
        #expect(try await provider(home).fetchStatus().usage == .noData)
    }

    @Test func apiKeyModeUsageIsUnsupported() async throws {
        let home = try makeHome(authMode: "apikey", idToken: nil, apiKey: "sk-fake")
        #expect(try await provider(home).fetchStatus().usage == .unsupported)
    }

    @Test func identity() {
        let provider = CodexProvider()
        #expect(provider.id == "codex")
        #expect(provider.displayName == "Codex")
        #expect(provider.iconName == "openai")
    }
}
