import Foundation
import Testing
@testable import AgentBarCore

private func date(_ iso: String) -> Date { DateParsing.iso8601(iso)! }

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let now = date("2026-11-12T10:00:00Z")

private func window(_ minutes: Int?, _ percent: Double, resets: String?) -> UsageWindow {
    UsageWindow(id: "w\(minutes ?? 0)", windowMinutes: minutes, usedPercent: percent, resetsAt: resets.map(date))
}

private func status(
    usage: UsageAvailability, state: SubscriptionStatus.State = .active, periodEnd: String? = nil
) -> Result<SubscriptionStatus, ProviderError> {
    .success(SubscriptionStatus(
        plan: Plan(rawValue: "plus", displayName: "ChatGPT Plus", shortName: "Plus"),
        state: state, periodEnd: periodEnd.map(date), usage: usage))
}

private func available(_ windows: UsageWindow...) -> UsageAvailability {
    .available(Usage(windows: windows, capturedAt: date("2026-11-12T09:35:00Z")))
}

@Suite struct UsageWindowTests {
    @Test(arguments: [
        (300, "5 小时"), (10080, "每周"), (1440, "每天"), (60, "1 小时"), (4320, "3 天"), (90, "90 分钟"),
    ])
    func names(minutes: Int, expected: String) {
        #expect(window(minutes, 0, resets: nil).name == expected)
    }

    @Test func customLabelWins() {
        #expect(UsageWindow(id: "billing_cycle", windowMinutes: nil, usedPercent: 0, resetsAt: nil,
                            label: "本计费周期").name == "本计费周期")
    }

    @Test func nameFallsBackToID() {
        #expect(UsageWindow(id: "primary", windowMinutes: nil, usedPercent: 0, resetsAt: nil).name == "primary")
    }

    @Test func notYetResetIsUnchanged() {
        let effective = window(300, 32, resets: "2026-11-12T12:15:00Z").effective(at: now)
        #expect(effective.usedPercent == 32)
        #expect(effective.isInferredReset == false)
    }

    @Test func pastResetTimeIsInferredAsReset() {
        let effective = window(300, 95, resets: "2026-11-12T09:59:00Z").effective(at: now)
        #expect(effective.usedPercent == 0)
        #expect(effective.isInferredReset == true)
    }

    @Test func noResetTimeIsUnchanged() {
        #expect(window(300, 50, resets: nil).effective(at: now).usedPercent == 50)
    }

    @Test func highestPercentUsesEffectiveValues() {
        let usage = Usage(windows: [
            window(300, 95, resets: "2026-11-12T09:00:00Z"),  // 已重置（推测）→ 0
            window(10080, 81, resets: "2026-11-14T00:00:00Z"),
        ], capturedAt: nil)
        #expect(usage.highestPercent(at: now) == 81)
        #expect(Usage(windows: [], capturedAt: nil).highestPercent(at: now) == nil)
    }

    @Test(arguments: [
        (UsageAvailability.unsupported, "暂不支持"),
        (.networkDisabled, "未开启联网获取"),
        (.noData, "暂无数据"),
        (.failed("接口返回 500"), "获取失败：接口返回 500"),
    ])
    func unavailableReasons(availability: UsageAvailability, expected: String) {
        #expect(availability.unavailableReason == expected)
    }

    @Test func defaultIsUnsupported() {
        #expect(SubscriptionStatus(plan: .unrecognized("x"), state: .active).usage == .unsupported)
    }
}

@Suite struct UsageWarningTests {
    let rules = WarningRules(calendar: utc)

    @Test func belowThresholdNoWarning() {
        let outcome = status(usage: available(window(10080, 79, resets: "2026-11-14T00:00:00Z")))
        #expect(rules.warnings(for: outcome, now: now).isEmpty)
    }

    @Test func atThreshold() {
        let outcome = status(usage: available(window(10080, 80, resets: "2026-11-14T00:00:00Z")))
        #expect(rules.warnings(for: outcome, now: now)
            == [Warning(short: "每周 80%", message: "每周额度已用 80%，11 月 14 日重置")])
    }

    @Test func exhausted() {
        let outcome = status(usage: available(window(300, 100, resets: "2026-11-12T12:15:00Z")))
        #expect(rules.warnings(for: outcome, now: now)
            == [Warning(short: "5 小时已用完", message: "5 小时额度已用完，2 小时 15 分后重置")])
    }

    @Test func customThreshold() {
        var rules = rules
        rules.usageThreshold = 90
        let outcome = status(usage: available(window(10080, 85, resets: "2026-11-14T00:00:00Z")))
        #expect(rules.warnings(for: outcome, now: now).isEmpty)
    }

    @Test func inferredResetDoesNotWarn() {
        let outcome = status(usage: available(window(300, 100, resets: "2026-11-12T09:00:00Z")))
        #expect(rules.warnings(for: outcome, now: now).isEmpty)
    }

    @Test func unavailableUsageDoesNotWarn() {
        #expect(rules.warnings(for: status(usage: .failed("x")), now: now).isEmpty)
    }

    @Test func warningsAreOrderedBySeverity() {
        let outcome = status(
            usage: available(
                window(10080, 85, resets: "2026-11-14T00:00:00Z"),
                window(300, 100, resets: "2026-11-12T12:15:00Z")),
            periodEnd: "2026-11-15T00:00:00Z")

        let shorts = rules.warnings(for: outcome, now: now).map(\.short)

        #expect(shorts == ["5 小时已用完", "3 天后到期", "每周 85%"])
        #expect(rules.warning(for: outcome, now: now)?.short == "5 小时已用完")
    }

    @Test func expiredComesBeforeExhausted() {
        let outcome = status(
            usage: available(window(300, 100, resets: "2026-11-12T12:15:00Z")),
            state: .expired, periodEnd: "2026-11-01T00:00:00Z")
        #expect(rules.warnings(for: outcome, now: now).map(\.short) == ["已过期", "5 小时已用完"])
    }
}

@Suite struct ResetTimeTests {
    let rules = WarningRules(calendar: utc)

    @Test(arguments: [
        ("2026-11-12T12:15:00Z", "2 小时 15 分后重置"),
        ("2026-11-12T13:00:00Z", "3 小时后重置"),
        ("2026-11-12T10:45:00Z", "45 分钟后重置"),
        ("2026-11-12T10:00:30Z", "即将重置"),
        ("2026-11-14T00:00:00Z", "11 月 14 日重置"),
    ])
    func resetText(resetsAt: String, expected: String) {
        #expect(rules.resetText(date(resetsAt), now: now) == expected)
    }
}

@Suite struct UsageStatusBarTests {
    let rules = WarningRules(calendar: utc)

    @Test func showsHighestPercent() {
        let outcome = status(usage: available(
            window(300, 32, resets: "2026-11-12T12:15:00Z"),
            window(10080, 50, resets: "2026-11-14T00:00:00Z")))
        #expect(rules.statusBarText(for: outcome, othersHaveWarning: false, style: .usagePercent, now: now) == "50%")
    }

    @Test func roundsPercent() {
        let outcome = status(usage: available(window(300, 32.6, resets: "2026-11-12T12:15:00Z")))
        #expect(rules.statusBarText(for: outcome, othersHaveWarning: true, style: .usagePercent, now: now) == "33% •")
    }

    @Test func warningOverridesPercent() {
        let outcome = status(usage: available(window(10080, 81, resets: "2026-11-14T00:00:00Z")))
        #expect(rules.statusBarText(for: outcome, othersHaveWarning: false, style: .usagePercent, now: now) == "每周 81%")
    }

    @Test func fallsBackToPlanNameWithoutUsage() {
        #expect(rules.statusBarText(
            for: status(usage: .unsupported), othersHaveWarning: false, style: .usagePercent, now: now) == "Plus")
    }
}

@Suite struct UsageSettingsTests {
    @Test func thresholdDefaultsTo80() {
        #expect(AppSettings().usageWarningThreshold == 80)
        #expect(WarningRules().usageThreshold == 80)
    }

    @Test func usagePercentStyleRoundTrips() throws {
        var settings = AppSettings()
        settings.statusBarStyle = .usagePercent
        settings.usageWarningThreshold = 90
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
