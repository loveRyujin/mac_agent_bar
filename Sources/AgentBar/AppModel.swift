import AgentBarCore
import Foundation

/// 界面状态。用 `ObservableObject` 而不是 `@Observable`，以支持 macOS 13。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var results: [ProviderResult] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?
    /// 当前显示的 agent（状态栏和面板共用）。
    @Published private(set) var selectedID: String?

    let rules = WarningRules()
    private let registry: ProviderRegistry
    private let defaults: UserDefaults
    private var refreshLoop: Task<Void, Never>?

    static let refreshInterval: Duration = .seconds(15 * 60)
    private static let preferredKey = "selectedProviderID"

    init(registry: ProviderRegistry = .standard, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        // 启动时刷新一次，之后每 15 分钟刷新一次。AppModel 与应用同生命周期，不需要取消。
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// 用户最后一次点选的 agent，重启后保持不变。回退显示其他 agent 时不改动它，
    /// 这样数据恢复后会自动切回来。
    private var preferredID: String? {
        get { defaults.string(forKey: Self.preferredKey) }
        set { defaults.set(newValue, forKey: Self.preferredKey) }
    }

    var selected: ProviderResult? {
        results.first { $0.provider.id == selectedID }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let results = await registry.refreshAll()
        self.results = results
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

    var statusBarText: String? {
        selected.map { rules.statusBarText(for: $0.outcome, now: Date()) }
    }
}
