import Foundation
import Testing
@testable import AgentBarCore

private func date(_ iso: String) -> Date { DateParsing.iso8601(iso)! }

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private struct StubProvider: Provider {
    let id: String
    let displayName: String
    func isInstalled() -> Bool { true }
    func fetchStatus() async throws -> SubscriptionStatus { fatalError() }
}

private func result(
    _ id: String = "codex", name: String = "Codex",
    state: SubscriptionStatus.State = .active, periodEnd: String? = nil, windows: [UsageWindow] = []
) -> ProviderResult {
    ProviderResult(
        provider: StubProvider(id: id, displayName: name),
        outcome: .success(SubscriptionStatus(
            plan: Plan(rawValue: "plus", displayName: "Plus"), state: state,
            periodEnd: periodEnd.map(date),
            usage: windows.isEmpty ? .unsupported : .available(Usage(windows: windows, capturedAt: nil)))))
}

private func failure(_ id: String = "cursor", name: String = "Cursor") -> ProviderResult {
    ProviderResult(provider: StubProvider(id: id, displayName: name),
                   outcome: .failure(.fileNotFound("~/x")))
}

private func fiveHour(_ percent: Double, resets: String) -> UsageWindow {
    UsageWindow(id: "five_hour", windowMinutes: 300, usedPercent: percent, resetsAt: date(resets))
}

@Suite struct NotificationRulesTests {
    let rules = NotificationRules(warningRules: WarningRules(calendar: utc))
    let now = date("2026-11-12T10:00:00Z")

    @Test func expiringSoonOncePerPeriodEnd() {
        var ledger = NotificationLedger()
        let soon = [result(periodEnd: "2026-11-15T00:00:00Z")]

        let first = rules.evaluate(results: soon, ledger: &ledger, now: now)
        #expect(first == [NotificationEvent(
            kind: .expiringSoon, providerID: "codex",
            title: "Codex 订阅快到期", body: "订阅将于 11 月 15 日到期（3 天后）")])
        #expect(rules.evaluate(results: soon, ledger: &ledger, now: now.addingTimeInterval(3600)).isEmpty)

        // 续费后进入下一个到期日，重新计算
        let renewed = [result(periodEnd: "2026-12-15T00:00:00Z")]
        #expect(rules.evaluate(results: renewed, ledger: &ledger, now: date("2026-12-10T00:00:00Z")).map(\.kind)
            == [.expiringSoon])
    }

    @Test func expiredOncePerPeriodEnd() {
        var ledger = NotificationLedger()
        let expired = [result(state: .expired, periodEnd: "2026-11-01T00:00:00Z")]

        #expect(rules.evaluate(results: expired, ledger: &ledger, now: now)
            == [NotificationEvent(kind: .expired, providerID: "codex",
                                  title: "Codex 订阅已过期", body: "订阅已于 11 月 1 日到期")])
        #expect(rules.evaluate(results: expired, ledger: &ledger, now: now).isEmpty)
    }

    @Test func expiringThenExpiredAreSeparateEvents() {
        var ledger = NotificationLedger()
        let end = "2026-11-13T00:00:00Z"
        #expect(rules.evaluate(results: [result(periodEnd: end)], ledger: &ledger, now: now).map(\.kind) == [.expiringSoon])
        #expect(rules.evaluate(results: [result(periodEnd: end)], ledger: &ledger, now: date("2026-11-13T01:00:00Z"))
            .map(\.kind) == [.expired])
    }

    @Test func usageHighOncePerCycle() {
        var ledger = NotificationLedger()
        let high = [result("claude-code", name: "Claude Code",
                           windows: [fiveHour(83, resets: "2026-11-12T13:10:00Z")])]

        #expect(rules.evaluate(results: high, ledger: &ledger, now: now) == [NotificationEvent(
            kind: .usageHigh, providerID: "claude-code",
            title: "Claude Code 额度快用完", body: "5 小时额度已用 83%，3 小时 10 分后重置")])
        // 同一周期内用得更多也不重复
        let higher = [result("claude-code", name: "Claude Code",
                             windows: [fiveHour(95, resets: "2026-11-12T13:10:00Z")])]
        #expect(rules.evaluate(results: higher, ledger: &ledger, now: now).isEmpty)
    }

    @Test func exhaustedWording() {
        var ledger = NotificationLedger()
        let used = [result("claude-code", name: "Claude Code", windows: [fiveHour(100, resets: "2026-11-12T13:10:00Z")])]
        let event = rules.evaluate(results: used, ledger: &ledger, now: now).first
        #expect(event?.title == "Claude Code 额度已用完")
        #expect(event?.body == "5 小时额度已用完，3 小时 10 分后重置")
    }

    @Test func resetAfterHighWindowPassesResetTime() {
        var ledger = NotificationLedger()
        let high = [result("claude-code", name: "Claude Code",
                           windows: [fiveHour(83, resets: "2026-11-12T13:10:00Z")])]
        _ = rules.evaluate(results: high, ledger: &ledger, now: now)

        // 还没到重置时间
        #expect(rules.evaluate(results: high, ledger: &ledger, now: date("2026-11-12T13:00:00Z")).isEmpty)
        // 过了重置时间（数据仍是旧快照）
        let after = date("2026-11-12T13:11:00Z")
        #expect(rules.evaluate(results: high, ledger: &ledger, now: after) == [NotificationEvent(
            kind: .usageReset, providerID: "claude-code",
            title: "Claude Code 额度已重置", body: "5 小时额度已重置")])
        #expect(rules.evaluate(results: high, ledger: &ledger, now: after).isEmpty)
    }

    @Test func belowThresholdNeverNotifies() {
        var ledger = NotificationLedger()
        let fine = [result(windows: [fiveHour(50, resets: "2026-11-12T13:10:00Z")])]
        #expect(rules.evaluate(results: fine, ledger: &ledger, now: now).isEmpty)
        #expect(rules.evaluate(results: fine, ledger: &ledger, now: date("2026-11-12T14:00:00Z")).isEmpty)
    }

    @Test func readFailureOncePerStreak() {
        var ledger = NotificationLedger()
        #expect(rules.evaluate(results: [failure()], ledger: &ledger, now: now) == [NotificationEvent(
            kind: .readFailure, providerID: "cursor", title: "Cursor 读取失败", body: "找不到 ~/x")])
        #expect(rules.evaluate(results: [failure()], ledger: &ledger, now: now).isEmpty)

        // 恢复后再失败，重新通知
        _ = rules.evaluate(results: [result("cursor", name: "Cursor")], ledger: &ledger, now: now)
        #expect(rules.evaluate(results: [failure()], ledger: &ledger, now: now).map(\.kind) == [.readFailure])
    }

    @Test func disabledKindsAreSkipped() {
        let quiet = NotificationRules(warningRules: WarningRules(calendar: utc), disabledKinds: [.readFailure, .expiringSoon])
        var ledger = NotificationLedger()
        let events = quiet.evaluate(
            results: [failure(), result(periodEnd: "2026-11-15T00:00:00Z")], ledger: &ledger, now: now)
        #expect(events.isEmpty)
    }

    @Test func survivesPersistence() throws {
        var ledger = NotificationLedger()
        let high = [result("claude-code", name: "Claude Code", windows: [fiveHour(83, resets: "2026-11-12T13:10:00Z")])]
        _ = rules.evaluate(results: high + [failure()], ledger: &ledger, now: now)

        let suite = "AgentBarTests-\(UUID().uuidString)"
        let store = NotificationLedgerStore(defaults: UserDefaults(suiteName: suite)!)
        store.save(ledger)
        var restored = store.load()

        #expect(restored == ledger)
        #expect(rules.evaluate(results: high + [failure()], ledger: &restored, now: now).isEmpty)
        #expect(rules.evaluate(results: high, ledger: &restored, now: date("2026-11-12T13:11:00Z")).map(\.kind)
            == [.usageReset])
    }

    @Test func emptyStoreLoadsEmptyLedger() {
        let store = NotificationLedgerStore(defaults: UserDefaults(suiteName: "AgentBarTests-\(UUID().uuidString)")!)
        #expect(store.load() == NotificationLedger())
    }

    @Test func settingsDisabledKindsDefaultEmptyAndRoundTrip() throws {
        #expect(AppSettings().disabledNotificationKinds.isEmpty)
        var settings = AppSettings()
        settings.disabledNotificationKinds = [.usageReset]
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}
