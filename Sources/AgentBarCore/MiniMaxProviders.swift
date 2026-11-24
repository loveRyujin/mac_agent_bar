import Foundation

/// mmx（MiniMax 官方 CLI）：登录状态和 Token Plan 用量都来自 mmx 自己的命令（见工单 13）。
public struct MmxProvider: Provider {
    public let id = "mmx"
    public let displayName = "mmx"
    public let iconName: String? = "minimax"

    private let config: HomeFile
    private let client: MmxClient
    private let fetchesUsage: Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        client: MmxClient,
        fetchesUsage: Bool = true
    ) {
        config = HomeFile(home: home, relativePath: ".mmx/config.json")
        self.client = client
        self.fetchesUsage = fetchesUsage
    }

    public func isInstalled() -> Bool { config.exists }

    public func fetchStatus() async throws -> SubscriptionStatus {
        switch await client.authStatus() {
        case .failed(let reason):
            throw ProviderError.unreadable(reason)
        case .signedOut:
            return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        case .signedIn(let method):
            return SubscriptionStatus(
                plan: Self.plan(method: method),
                state: .active,
                usage: fetchesUsage ? Self.ownUsage(await client.quota()) : .networkDisabled)
        }
    }

    /// mmx 自己的页签不需要注明“数据来自 mmx”。
    static func ownUsage(_ availability: UsageAvailability) -> UsageAvailability {
        guard case .available(var usage) = availability else { return availability }
        usage.source = nil
        return .available(usage)
    }

    /// OAuth 登录对应 Token Plan；API key 登录原样显示。
    static func plan(method: String) -> Plan {
        switch method {
        case "oauth": Plan(rawValue: method, displayName: "Token Plan")
        case "api_key", "apikey": Plan(rawValue: method, displayName: "API key")
        default: .unrecognized(method)
        }
    }
}

/// MiniMax Code 桌面应用：登录状态来自 `auth-state.json` 的非敏感字段；用量借用 mmx 的结果
/// （同一个 MiniMax 账号，见工单 12）。不读取 `auth.json`、`refresh` 等凭据文件。
public struct MiniMaxCodeProvider: Provider {
    public let id = "minimax-code"
    public let displayName = "MiniMax Code"
    public let iconName: String? = "minimax"

    private let home: URL
    private let config: HomeFile
    private let appURL: URL
    private let mmx: MmxClient
    private let mmxInstalled: @Sendable () -> Bool
    private let fetchesUsage: Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appURL: URL = URL(fileURLWithPath: "/Applications/MiniMax Code.app"),
        mmx: MmxClient,
        mmxInstalled: @escaping @Sendable () -> Bool = { MmxClient.isInstalled() },
        fetchesUsage: Bool = true
    ) {
        self.home = home
        config = HomeFile(home: home, relativePath: ".minimax/config.yaml")
        self.appURL = appURL
        self.mmx = mmx
        self.mmxInstalled = mmxInstalled
        self.fetchesUsage = fetchesUsage
    }

    public func isInstalled() -> Bool {
        config.exists || FileManager.default.fileExists(atPath: appURL.path)
    }

    public func fetchStatus() async throws -> SubscriptionStatus {
        guard isAuthenticated() else {
            return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        }
        let usage: UsageAvailability
        if !fetchesUsage {
            usage = .networkDisabled
        } else if !mmxInstalled() {
            usage = .unsupported
        } else {
            usage = await mmx.quota()
        }
        return SubscriptionStatus(
            plan: Plan(rawValue: "", displayName: "已登录"),
            state: .active,
            usage: usage)
    }

    /// 任一区域的 `~/.minimax/auth/prod/<region>/mcode-public/auth-state.json` 是已登录状态。
    private func isAuthenticated() -> Bool {
        let prod = home.appendingPathComponent(".minimax/auth/prod", isDirectory: true)
        guard let regions = try? FileManager.default.contentsOfDirectory(atPath: prod.path) else { return false }
        return regions.contains { region in
            let file = prod.appendingPathComponent("\(region)/mcode-public/auth-state.json")
            guard let data = try? Data(contentsOf: file),
                  let state = try? JSONDecoder().decode(AuthState.self, from: data)
            else { return false }
            return state.status == "authenticated"
        }
    }
}

/// `auth-state.json` 中只取非敏感字段。
private struct AuthState: Decodable {
    let status: String?
}
