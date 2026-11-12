import Foundation
import Testing
@testable import AgentBarCore

@Suite struct AppSettingsTests {
    @Test func defaultsMatchSpec() {
        let settings = AppSettings()
        #expect(settings.launchAtLogin == true)
        #expect(settings.refreshInterval == .fifteenMinutes)
        #expect(settings.hiddenProviderIDs.isEmpty)
        #expect(settings.hideEmail == false)
        #expect(settings.statusBarStyle == .planName)
        #expect(settings.expiryWarningDays == 7)
    }

    @Test func refreshIntervalChoices() {
        #expect(AppSettings.RefreshInterval.allCases.map(\.minutes) == [5, 15, 30, 60])
        #expect(AppSettings.RefreshInterval.thirtyMinutes.duration == .seconds(30 * 60))
    }
}

@Suite struct SettingsStoreTests {
    /// 每个测试用独立的 UserDefaults，互不干扰。
    func makeStore() -> (SettingsStore, UserDefaults) {
        let suite = "AgentBarTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsStore(defaults: defaults), defaults)
    }

    @Test func nothingStoredLoadsDefaults() {
        let (store, _) = makeStore()
        #expect(store.load() == AppSettings())
    }

    @Test func roundTrip() {
        let (store, _) = makeStore()
        var settings = AppSettings()
        settings.launchAtLogin = false
        settings.refreshInterval = .fiveMinutes
        settings.hiddenProviderIDs = ["cursor"]
        settings.hideEmail = true
        settings.statusBarStyle = .iconOnly
        settings.expiryWarningDays = 3

        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test func missingFieldsFallBackToDefaultsIndividually() {
        let (store, defaults) = makeStore()
        defaults.set(Data(#"{"hideEmail": true}"#.utf8), forKey: SettingsStore.key)

        var expected = AppSettings()
        expected.hideEmail = true
        #expect(store.load() == expected)
    }

    @Test func unknownValueOnlyResetsThatField() {
        let (store, defaults) = makeStore()
        let json = #"{"statusBarStyle": "rainbow", "refreshInterval": 7, "expiryWarningDays": 3}"#
        defaults.set(Data(json.utf8), forKey: SettingsStore.key)

        let settings = store.load()

        #expect(settings.statusBarStyle == .planName)
        #expect(settings.refreshInterval == .fifteenMinutes)
        #expect(settings.expiryWarningDays == 3)
    }

    @Test func corruptDataLoadsDefaults() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        #expect(store.load() == AppSettings())
    }
}

// MARK: - 设置对显示的影响

private struct StubProvider: Provider {
    let id: String
    var installed = true
    var displayName: String { id }
    func isInstalled() -> Bool { installed }
    func fetchStatus() async throws -> SubscriptionStatus {
        SubscriptionStatus(plan: Plan(rawValue: "pro", displayName: "Pro"), state: .active)
    }
}

@Suite struct HiddenProvidersTests {
    let registry = ProviderRegistry(providers: [
        StubProvider(id: "claude-code"),
        StubProvider(id: "codex"),
        StubProvider(id: "cursor", installed: false),
    ])

    @Test func hiddenProvidersAreNotRefreshed() async {
        let results = await registry.refreshAll(hiding: ["codex"])
        #expect(results.map(\.provider.id) == ["claude-code"])
    }

    @Test func installedProvidersIncludeHiddenOnes() {
        #expect(registry.installedProviders().map(\.id) == ["claude-code", "codex"])
    }

    @Test func hiddenPreferenceFallsBack() async {
        let results = await registry.refreshAll(hiding: ["codex"])
        let selected = Selection.resolve(
            preferred: "codex", registryOrder: registry.providers.map(\.id), results: results)
        #expect(selected == "claude-code")
    }
}

@Suite struct EmailRedactionTests {
    @Test func redactsAccountOrganizationAndDetails() {
        let status = SubscriptionStatus(
            plan: Plan(rawValue: "claude_max", displayName: "Max"),
            state: .active,
            account: "max-user@example.com",
            organization: "max-user@example.com's Organization",
            details: [Detail("billingType", "stripe_subscription"), Detail("owner", "a.b+c@sub.example.org")]
        )

        let redacted = status.redactingEmails()

        #expect(redacted.account == "•••@•••")
        #expect(redacted.organization == "•••@•••'s Organization")
        #expect(redacted.details == [Detail("billingType", "stripe_subscription"), Detail("owner", "•••@•••")])
        #expect(redacted.plan == status.plan)
    }

    @Test func leavesTextWithoutEmailsAlone() {
        let status = SubscriptionStatus(
            plan: Plan(rawValue: "pro", displayName: "Pro"), state: .active, organization: "Example Org")
        #expect(status.redactingEmails() == status)
    }
}

@Suite struct ExpiryWarningDaysTests {
    let now = DateParsing.iso8601("2026-11-11T10:00:00Z")!

    func rules(days: Int) -> WarningRules {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return WarningRules(calendar: calendar, warningDays: days)
    }

    func ending(_ iso: String) -> Result<SubscriptionStatus, ProviderError> {
        .success(SubscriptionStatus(
            plan: Plan(rawValue: "plus", displayName: "Plus"), state: .active,
            periodEnd: DateParsing.iso8601(iso)))
    }

    @Test func customWarningDays() {
        #expect(rules(days: 3).warning(for: ending("2026-11-14T00:00:00Z"), now: now)?.short == "3 天后到期")
        #expect(rules(days: 3).warning(for: ending("2026-11-15T00:00:00Z"), now: now) == nil)
    }

    @Test func defaultIsSevenDays() {
        #expect(WarningRules().warningDays == 7)
    }
}

@Suite struct StatusBarTextTests {
    let rules = WarningRules()
    let now = Date()
    let fine: Result<SubscriptionStatus, ProviderError> =
        .success(SubscriptionStatus(plan: Plan(rawValue: "plus", displayName: "ChatGPT Plus", shortName: "Plus"), state: .active))
    let broken: Result<SubscriptionStatus, ProviderError> = .failure(.unreadable("x"))

    @Test func planNameStyle() {
        #expect(rules.statusBarText(for: fine, othersHaveWarning: false, style: .planName, now: now) == "Plus")
        #expect(rules.statusBarText(for: fine, othersHaveWarning: true, style: .planName, now: now) == "Plus •")
        #expect(rules.statusBarText(for: broken, othersHaveWarning: false, style: .planName, now: now) == "读取失败")
        #expect(rules.statusBarText(for: nil, othersHaveWarning: false, style: .planName, now: now) == nil)
    }

    @Test func iconOnlyStyleShowsDotForAnyWarning() {
        #expect(rules.statusBarText(for: fine, othersHaveWarning: false, style: .iconOnly, now: now) == nil)
        #expect(rules.statusBarText(for: fine, othersHaveWarning: true, style: .iconOnly, now: now) == "•")
        #expect(rules.statusBarText(for: broken, othersHaveWarning: false, style: .iconOnly, now: now) == "•")
    }
}

@Suite struct ProviderResultRedactionTests {
    @Test func redactsSuccessAndKeepsFailure() throws {
        let ok = ProviderResult(
            provider: StubProvider(id: "codex"),
            outcome: .success(SubscriptionStatus(
                plan: Plan(rawValue: "plus", displayName: "Plus"), state: .active, account: "a@example.com")))
        let failed = ProviderResult(provider: StubProvider(id: "cursor"), outcome: .failure(.unreadable("x")))

        #expect(try ok.redactingEmails().outcome.get().account == "•••@•••")
        #expect(failed.redactingEmails().outcome == .failure(.unreadable("x")))
        #expect(ok.redactingEmails().provider.id == "codex")
    }
}
