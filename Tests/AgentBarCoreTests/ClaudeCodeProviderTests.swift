import Foundation
import Testing
@testable import AgentBarCore

@Suite struct ClaudeCodeProviderTests {
    /// fixture 里的 `profileFetchedAt`（毫秒时间戳）。
    let profileFetchedAt = Date(timeIntervalSince1970: 1_794_366_803.153)
    let now = ISO8601DateFormatter().date(from: "2026-11-11T00:00:00Z")!

    func provider(_ fixture: String, now: Date? = nil) throws -> ClaudeCodeProvider {
        let now = now ?? self.now
        return ClaudeCodeProvider(home: try TestHome(fixture: fixture).url, now: { now })
    }

    @Test func team() async throws {
        let status = try await provider("claude-team").fetchStatus()

        #expect(status.plan == Plan(rawValue: "claude_team/team_standard", displayName: "Team · Standard"))
        #expect(status.state == .active)
        #expect(status.account == "team-user@example.com")
        #expect(status.organization == "Example Org")
        #expect(status.periodEnd == nil)
        #expect(status.sourceUpdatedAt == profileFetchedAt)
        #expect(status.details == [
            Detail("billingType", "stripe_subscription"),
            Detail("userRateLimitTier", "default_raven"),
            Detail("hasExtraUsageEnabled", "true"),
        ])
        // 已登录但没有用量缓存
        #expect(status.usage == .noData)
    }

    @Test func personalMax() async throws {
        let status = try await provider("claude-max").fetchStatus()

        #expect(status.plan == Plan(rawValue: "claude_max", displayName: "Max 20x"))
        #expect(status.state == .active)
        #expect(status.account == "max-user@example.com")
    }

    @Test func trial() async throws {
        let status = try await provider("claude-trial").fetchStatus()

        #expect(status.plan.displayName == "Pro")
        #expect(status.state == .trial)
        #expect(status.periodEnd == ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z"))
    }

    @Test func trialInThePastIsExpired() async throws {
        let later = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        let status = try await provider("claude-trial", now: later).fetchStatus()

        #expect(status.state == .expired)
    }

    @Test func noOAuthAccountIsSignedOut() async throws {
        let provider = try provider("claude-no-oauth")
        #expect(provider.isInstalled())

        let status = try await provider.fetchStatus()

        #expect(status.state == .signedOut)
        #expect(status.account == nil)
        #expect(status.details.isEmpty)
    }

    @Test func unknownSeatTierIsShownRaw() async throws {
        let status = try await provider("claude-unknown-seat").fetchStatus()

        #expect(status.plan == Plan(rawValue: "claude_team/team_galactic", displayName: "Team · team_galactic"))
        #expect(status.state == .active)
    }

    @Test(arguments: [
        ("claude_enterprise", "enterprise_premium", nil, "Enterprise · Premium"),
        ("claude_max", nil, "default_claude_max_5x", "Max 5x"),
        ("claude_max", nil, nil, "Max"),
        ("claude_pro", nil, nil, "Pro"),
        ("claude_mystery", nil, nil, "claude_mystery"),
    ] as [(String, String?, String?, String)])
    func planNames(organizationType: String, seatTier: String?, rateLimitTier: String?, expected: String) {
        let plan = ClaudeCodeProvider.plan(
            organizationType: organizationType, seatTier: seatTier, userRateLimitTier: rateLimitTier)
        #expect(plan?.displayName == expected)
    }

    @Test func missingFieldsDoNotThrow() async throws {
        let status = try await provider("claude-missing-fields").fetchStatus()

        #expect(status.plan.displayName == "未知套餐")
        #expect(status.state == .unknown)
        #expect(status.account == nil)
        #expect(status.sourceUpdatedAt == nil)
    }

    @Test func invalidJSONThrowsReadableError() async throws {
        await #expect(throws: ProviderError.unreadable("~/.claude.json 格式无法解析")) {
            try await provider("claude-invalid-json").fetchStatus()
        }
    }

    @Test func missingFileIsNotInstalledAndThrowsFileNotFound() async throws {
        let provider = ClaudeCodeProvider(home: try TestHome().url)
        #expect(!provider.isInstalled())
        await #expect(throws: ProviderError.fileNotFound("~/.claude.json")) {
            try await provider.fetchStatus()
        }
    }

    @Test func usageFromLocalCache() async throws {
        let status = try await provider("claude-usage").fetchStatus()
        let usage = try #require(status.usage.usage)

        #expect(usage.capturedAt == Date(timeIntervalSince1970: 1_794_469_627.588))
        #expect(usage.windows == [
            UsageWindow(id: "five_hour", windowMinutes: 300, usedPercent: 80,
                        resetsAt: DateParsing.iso8601("2026-11-12T11:10:00.490Z")),
            UsageWindow(id: "seven_day", windowMinutes: 10080, usedPercent: 22,
                        resetsAt: DateParsing.iso8601("2026-11-14T03:00:00.490Z")),
            UsageWindow(id: "seven_day_opus", windowMinutes: 10080, usedPercent: 41.5,
                        resetsAt: DateParsing.iso8601("2026-11-14T03:00:00Z"), label: "每周（Opus）"),
        ])
        #expect(usage.windows.map(\.name) == ["5 小时", "每周", "每周（Opus）"])
        // 订阅信息不受影响
        #expect(status.plan.displayName == "Team · Standard")
    }

    @Test func usageCacheFromAnotherAccountIsNoData() async throws {
        #expect(try await provider("claude-usage-other-account").fetchStatus().usage == .noData)
    }

    @Test func corruptUsageCacheOnlyAffectsUsage() async throws {
        let status = try await provider("claude-usage-corrupt").fetchStatus()
        #expect(status.usage == .failed("用量缓存格式无法识别"))
        #expect(status.plan.displayName == "Pro")
        #expect(status.state == .active)
    }

    @Test func signedOutUsageIsUnsupported() async throws {
        #expect(try await provider("claude-no-oauth").fetchStatus().usage == .unsupported)
    }

    @Test func identity() {
        let provider = ClaudeCodeProvider()
        #expect(provider.id == "claude-code")
        #expect(provider.displayName == "Claude Code")
        #expect(provider.iconName == "claude")
    }
}
