import AgentBarCore
import Foundation

/// 界面状态。用 `ObservableObject` 而不是 `@Observable`，以支持 macOS 13。
@MainActor
final class AppModel: ObservableObject {
    /// 最近一次刷新的原始结果；界面读取 `results`（按设置处理过）。
    @Published private var rawResults: [ProviderResult] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    /// 当前显示的 agent（状态栏和面板共用）。
    @Published private(set) var selectedID: String?

    /// 用户设置。修改后立即保存并生效。
    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    /// 开机自启（以系统登录项的实际状态为准）。
    let launchAtLogin: LaunchAtLogin

    /// Cursor 用量获取器，与应用同生命周期（记住钥匙串被拒绝的时间、缓存 cursor-agent 版本号）。
    private let cursorUsage = CursorUsageFetcher()
    private let defaults: UserDefaults
    private let settingsStore: SettingsStore
    private var refreshLoop: Task<Void, Never>?

    private static let preferredKey = "selectedProviderID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settingsStore = SettingsStore(defaults: defaults)
        let settings = settingsStore.load()
        self.settings = settings
        launchAtLogin = LaunchAtLogin(defaults: defaults, settings: settings)
        startRefreshLoop(refreshFirst: true)
    }

    /// 定时刷新。AppModel 与应用同生命周期；只在刷新间隔改变时重启。
    private func startRefreshLoop(refreshFirst: Bool) {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            var shouldRefresh = refreshFirst
            while !Task.isCancelled {
                if shouldRefresh { await self?.refresh() }
                shouldRefresh = true
                guard let interval = self?.settings.refreshInterval.duration else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func settingsDidChange(from old: AppSettings) {
        settingsStore.save(settings)
        if settings.refreshInterval != old.refreshInterval {
            startRefreshLoop(refreshFirst: false)
        }
        if settings.onlineUsageProviderIDs.contains("cursor"), !old.onlineUsageProviderIDs.contains("cursor") {
            // 重新打开开关：允许再次请求钥匙串授权
            cursorUsage.resetKeychainDenial()
        }
        if settings.hiddenProviderIDs != old.hiddenProviderIDs
            || settings.onlineUsageProviderIDs != old.onlineUsageProviderIDs {
            Task { await refresh() }
        }
    }

    /// 用户最后一次点选的 agent，重启后保持不变。回退显示其他 agent 时不改动它，
    /// 这样数据恢复后会自动切回来。
    private var preferredID: String? {
        get { defaults.string(forKey: Self.preferredKey) }
        set { defaults.set(newValue, forKey: Self.preferredKey) }
    }

    /// 按当前设置构建的注册表（是否联网获取用量取决于设置）。
    private var registry: ProviderRegistry {
        .standard(settings: settings, cursorUsage: cursorUsage)
    }

    var rules: WarningRules {
        WarningRules(warningDays: settings.expiryWarningDays, usageThreshold: settings.usageWarningThreshold)
    }

    /// 界面显示的结果：开启“隐藏邮箱”时其中的邮箱已被替换。
    var results: [ProviderResult] {
        settings.hideEmail ? rawResults.map { $0.redactingEmails() } : rawResults
    }

    var selected: ProviderResult? {
        results.first { $0.provider.id == selectedID }
    }

    /// 已安装的 agent（包括被隐藏的），供设置界面列出。
    var installedProviders: [any Provider] {
        registry.installedProviders()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let results = await registry.refreshAll(hiding: settings.hiddenProviderIDs)
        rawResults = results
        selectedID = Selection.resolve(
            preferred: preferredID, registryOrder: registry.providers.map(\.id), results: results)
        lastRefreshedAt = Date()
        isRefreshing = false
    }

    /// 用户点击页签：面板和状态栏都切换过去，并记住这个选择。
    func select(_ id: String) {
        preferredID = id
        selectedID = id
    }

    func warning(for result: ProviderResult) -> Warning? {
        rules.warning(for: result.outcome, now: Date())
    }

    /// 当前没显示的 agent 里有没有需要警示的。
    var othersHaveWarning: Bool {
        results.contains { $0.provider.id != selectedID && warning(for: $0) != nil }
    }

    /// 状态栏 logo 旁边的文字；nil 表示只显示 logo。
    var statusBarText: String? {
        rules.statusBarText(
            for: selected?.outcome, othersHaveWarning: othersHaveWarning,
            style: settings.statusBarStyle, now: Date())
    }
}
