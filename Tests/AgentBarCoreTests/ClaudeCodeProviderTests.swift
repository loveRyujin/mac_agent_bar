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
        #expect(status.usage == .unsupported)
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

    @Test func identity() {
        let provider = ClaudeCodeProvider()
        #expect(provider.id == "claude-code")
        #expect(provider.displayName == "Claude Code")
        #expect(provider.iconName == "claude")
    }
}
