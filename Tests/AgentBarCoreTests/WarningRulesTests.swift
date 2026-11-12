import Foundation
import Testing
@testable import AgentBarCore

private func date(_ iso: String) -> Date { DateParsing.iso8601(iso)! }

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let plus = Plan(rawValue: "plus", displayName: "ChatGPT Plus", shortName: "Plus")

private func active(until periodEnd: String?, state: SubscriptionStatus.State = .active)
    -> Result<SubscriptionStatus, ProviderError>
{
    .success(SubscriptionStatus(plan: plus, state: state, periodEnd: periodEnd.map(date)))
}

@Suite struct WarningRulesTests {
    let rules = WarningRules(calendar: utc)
    let now = date("2026-11-11T10:00:00Z")

    @Test func readFailureIsAWarning() {
        let warning = rules.warning(for: .failure(.fileNotFound("~/.codex/auth.json")), now: now)
        #expect(warning == Warning(short: "读取失败", message: "找不到 ~/.codex/auth.json"))
    }

    @Test func noPeriodEndNoAlert() {
        #expect(rules.warning(for: active(until: nil), now: now) == nil)
    }

    @Test func sevenDayBoundary() {
        // 第 7 天（即使时刻早于当前时刻）仍然警示
        #expect(rules.warning(for: active(until: "2026-11-18T09:00:00Z"), now: now)
            == Warning(short: "7 天后到期", message: "订阅将于 11 月 18 日到期（7 天后）"))
        #expect(rules.warning(for: active(until: "2026-11-18T23:59:59Z"), now: now)?.short == "7 天后到期")
        // 第 8 天不警示
        #expect(rules.warning(for: active(until: "2026-11-19T00:00:00Z"), now: now) == nil)
    }

    @Test func todayAndTomorrow() {
        #expect(rules.warning(for: active(until: "2026-11-11T23:00:00Z"), now: now)
            == Warning(short: "今天到期", message: "订阅将于 11 月 11 日到期（今天）"))
        #expect(rules.warning(for: active(until: "2026-11-12T01:00:00Z"), now: now)
            == Warning(short: "明天到期", message: "订阅将于 11 月 12 日到期（明天）"))
    }

    @Test func trialEndingSoonMentionsTrial() {
        let warning = rules.warning(for: active(until: "2026-11-14T00:00:00Z", state: .trial), now: now)
        #expect(warning == Warning(short: "3 天后到期", message: "试用将于 11 月 14 日到期（3 天后）"))
    }

    @Test func expiredState() {
        #expect(rules.warning(for: active(until: "2026-11-01T00:00:00Z", state: .expired), now: now)
            == Warning(short: "已过期", message: "订阅已于 11 月 1 日到期"))
        #expect(rules.warning(for: active(until: nil, state: .expired), now: now)
            == Warning(short: "已过期", message: "订阅已过期"))
    }

    @Test func periodEndInThePastIsExpiredEvenIfStateSaysActive() {
        // 当天早些时候已过的到期时间也算过期
        #expect(rules.warning(for: active(until: "2026-11-11T09:00:00Z"), now: now)?.short == "已过期")
        #expect(rules.warning(for: active(until: "2026-11-01T00:00:00Z"), now: now)?.short == "已过期")
    }

    @Test func signedOutAndUnknownAreNotWarnings() {
        let signedOut = SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        #expect(rules.warning(for: .success(signedOut), now: now) == nil)
    }

    @Test func statusBarText() {
        #expect(rules.statusBarText(for: active(until: nil), othersHaveWarning: false, style: .planName, now: now) == "Plus")
        #expect(rules.statusBarText(for: active(until: "2026-11-14T00:00:00Z"), othersHaveWarning: false, style: .planName, now: now) == "3 天后到期")
        #expect(rules.statusBarText(for: .failure(.unreadable("x")), othersHaveWarning: false, style: .planName, now: now) == "读取失败")
    }

    @Test func dateFormatting() {
        #expect(rules.formatDate(date("2026-11-22T08:00:00Z"), now: now) == "11 月 22 日")
        #expect(rules.formatDate(date("2027-01-03T08:00:00Z"), now: now) == "2027 年 1 月 3 日")
    }

    @Test(arguments: [(0, "今天"), (1, "明天"), (11, "11 天后"), (-1, "昨天"), (-5, "5 天前")])
    func relativeDays(days: Int, expected: String) {
        #expect(rules.relativeDays(days) == expected)
    }

    @Test func shortNameDefaultsToDisplayName() {
        #expect(Plan(rawValue: "pro_plus", displayName: "Pro+").shortName == "Pro+")
    }
}

// MARK: - 选中与回退

private struct StubProvider: Provider {
    let id: String
    var displayName: String { id }
    func isInstalled() -> Bool { true }
    func fetchStatus() async throws -> SubscriptionStatus { fatalError() }
}

private func ok(_ id: String) -> ProviderResult {
    ProviderResult(provider: StubProvider(id: id), outcome: active(until: nil))
}

private func failed(_ id: String) -> ProviderResult {
    ProviderResult(provider: StubProvider(id: id), outcome: .failure(.unreadable("坏了")))
}

@Suite struct SelectionTests {
    let order = ["claude-code", "codex", "cursor"]

    @Test func noPreferenceSelectsFirstSuccessful() {
        #expect(Selection.resolve(preferred: nil, registryOrder: order,
                                  results: [failed("claude-code"), ok("codex"), ok("cursor")]) == "codex")
    }

    @Test func keepsSuccessfulPreference() {
        #expect(Selection.resolve(preferred: "cursor", registryOrder: order,
                                  results: [ok("claude-code"), ok("codex"), ok("cursor")]) == "cursor")
    }

    @Test func uninstalledPreferenceFallsBackToNextInRegistryOrder() {
        #expect(Selection.resolve(preferred: "codex", registryOrder: order,
                                  results: [ok("claude-code"), ok("cursor")]) == "cursor")
        // 往后找不到时从头绕回来
        #expect(Selection.resolve(preferred: "cursor", registryOrder: order,
                                  results: [ok("claude-code"), ok("codex")]) == "claude-code")
    }

    @Test func failedPreferenceFallsBackToNextSuccessful() {
        #expect(Selection.resolve(preferred: "claude-code", registryOrder: order,
                                  results: [failed("claude-code"), failed("codex"), ok("cursor")]) == "cursor")
    }

    @Test func allFailedKeepsInstalledPreferenceOtherwiseFirstInstalled() {
        #expect(Selection.resolve(preferred: "codex", registryOrder: order,
                                  results: [failed("claude-code"), failed("codex")]) == "codex")
        #expect(Selection.resolve(preferred: "cursor", registryOrder: order,
                                  results: [failed("claude-code"), failed("codex")]) == "claude-code")
    }

    @Test func unknownPreferenceIsTreatedAsNoPreference() {
        #expect(Selection.resolve(preferred: "removed-agent", registryOrder: order,
                                  results: [ok("codex")]) == "codex")
    }

    @Test func nothingInstalled() {
        #expect(Selection.resolve(preferred: "codex", registryOrder: order, results: []) == nil)
    }
}
