import AgentBarCore
import AppKit

/// 界面状态。用 `ObservableObject` 而不是 `@Observable`，以支持 macOS 13。
@MainActor
final class AppModel: ObservableObject {
    /// 最近一次刷新的原始结果；界面读取 `results`（按设置处理过）。
    @Published private var rawResults: [ProviderResult] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    /// 当前显示的 agent（状态栏和面板共用）。
    @Published private(set) var selectedID: String?

    /// 插件文件夹里的插件及其状态（已开启 / 待确认 / 出错）。
    @Published private(set) var plugins: [PluginItem] = []

    /// 用户设置。修改后立即保存并生效。
    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    /// 开机自启（以系统登录项的实际状态为准）。
    let launchAtLogin: LaunchAtLogin

    /// Cursor 用量获取器，与应用同生命周期（记住钥匙串被拒绝的时间、缓存 cursor-agent 版本号）。
    private let cursorUsage = CursorUsageFetcher()
    /// Gemini 用量获取器，与应用同生命周期（在内存中缓存刷新得到的 access token）。
    private let geminiUsage = GeminiUsageFetcher()
    /// mmx 客户端，mmx 和 MiniMax Code 两个 provider 共用（同一次刷新只调用一次 mmx）。
    private let mmx = MmxClient()

    /// 系统通知。去重记录持久化保存，重启后不会重复通知。
    let notifier = Notifier()
    private let ledgerStore: NotificationLedgerStore
    private var ledger: NotificationLedger
    private let defaults: UserDefaults
    private let settingsStore: SettingsStore
    private var refreshLoop: Task<Void, Never>?
    private var pluginWatcher: PluginFolderWatcher?

    private static let preferredKey = "selectedProviderID"

    init(defaults: UserDefaults = .standard) {
        // bundle id 更换后，第一次启动时把旧 id 下的偏好搬过来
        if let legacy = UserDefaults(suiteName: PreferencesMigration.legacyDomain) {
            PreferencesMigration.migrate(from: legacy, to: defaults)
        }
        self.defaults = defaults
        settingsStore = SettingsStore(defaults: defaults)
        let settings = settingsStore.load()
        self.settings = settings
        ledgerStore = NotificationLedgerStore(defaults: defaults)
        ledger = ledgerStore.load()
        launchAtLogin = LaunchAtLogin(defaults: defaults, settings: settings)
        try? FileManager.default.createDirectory(at: PluginDiscovery.root(), withIntermediateDirectories: true)
        reloadPlugins(refreshIfChanged: false)
        pluginWatcher = PluginFolderWatcher(directory: PluginDiscovery.root()) { [weak self] in
            self?.reloadPlugins()
        }
        startRefreshLoop(refreshFirst: true)
        // 点击通知：切换到对应 agent 并打开面板
        notifier.onOpen = { [weak self] id in
            self?.select(id)
            StatusItemPanel.open()
        }
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
        if settings.trustedPlugins != old.trustedPlugins {
            reloadPlugins(refreshIfChanged: false)
        }
        if settings.hiddenProviderIDs != old.hiddenProviderIDs
            || settings.trustedPlugins != old.trustedPlugins
            || settings.onlineUsageProviderIDs != old.onlineUsageProviderIDs
            || settings.minimaxUsageViaMmx != old.minimaxUsageViaMmx {
            Task { await refresh() }
        }
    }

    /// 用户最后一次点选的 agent，重启后保持不变。回退显示其他 agent 时不改动它，
    /// 这样数据恢复后会自动切回来。
    private var preferredID: String? {
        get { defaults.string(forKey: Self.preferredKey) }
        set { defaults.set(newValue, forKey: Self.preferredKey) }
    }

    /// 按当前设置构建的注册表（是否联网获取用量取决于设置）；只包含用户已确认的插件。
    private var registry: ProviderRegistry {
        .standard(settings: settings, cursorUsage: cursorUsage, geminiUsage: geminiUsage, mmx: mmx,
                  plugins: PluginCatalog.enabledProviders(plugins))
    }

    // MARK: - 插件

    /// 重新扫描插件文件夹。会运行的插件有变化（新确认、内容改动、删除）时重新刷新。
    func reloadPlugins(refreshIfChanged: Bool = true) {
        let old = plugins
        let new = PluginCatalog.load(trusted: settings.trustedPlugins)
        guard new != old else { return }
        plugins = new
        func running(_ items: [PluginItem]) -> [String] {
            items.filter { $0.state == .enabled }.map { "\($0.id):\($0.fingerprint ?? "")" }
        }
        if refreshIfChanged, running(new) != running(old) {
            Task { await refresh() }
        }
    }

    /// 开启时记下用户确认时看到的内容指纹；之后内容一变就需要重新确认。
    func setPlugin(_ item: PluginItem, enabled: Bool) {
        if enabled, let fingerprint = item.fingerprint {
            settings.trustedPlugins[item.id] = fingerprint
        } else {
            settings.trustedPlugins.removeValue(forKey: item.id)
        }
    }

    func openPluginFolder() {
        let root = PluginDiscovery.root()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
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
        // 文件夹监听可能漏掉改动（例如睡眠期间），每次刷新前再扫描一次
        reloadPlugins(refreshIfChanged: false)
        let results = await registry.refreshAll(hiding: settings.hiddenProviderIDs)
        rawResults = results
        selectedID = Selection.resolve(
            preferred: preferredID, registryOrder: registry.providers.map(\.id), results: results)
        lastRefreshedAt = Date()
        isRefreshing = false
        await notify(about: results)
    }

    private func notify(about results: [ProviderResult]) async {
        let rules = NotificationRules(warningRules: rules, disabledKinds: settings.disabledNotificationKinds)
        let events = rules.evaluate(results: results, ledger: &ledger, now: Date())
        ledgerStore.save(ledger)
        await notifier.send(events)
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
