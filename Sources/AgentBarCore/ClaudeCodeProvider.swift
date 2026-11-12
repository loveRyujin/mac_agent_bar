import Foundation

/// 读取 `~/.claude.json` 里的 `oauthAccount`。
public struct ClaudeCodeProvider: Provider {
    public let id = "claude-code"
    public let displayName = "Claude Code"
    public let iconName: String? = "claude"

    private let file: HomeFile
    private let now: @Sendable () -> Date

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        file = HomeFile(home: home, relativePath: ".claude.json")
        self.now = now
    }

    /// 文件存在就算已安装；没有 `oauthAccount` 时显示为未登录。
    public func isInstalled() -> Bool { file.exists }

    public func fetchStatus() async throws -> SubscriptionStatus {
        let data = try file.read()
        let root: Root
        do {
            root = try JSONDecoder().decode(Root.self, from: data)
        } catch {
            throw ProviderError.unreadable("\(file.displayPath) 格式无法解析")
        }
        guard let account = root.oauthAccount else {
            return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        }
        var status = status(from: account)
        status.usage = Self.usage(from: data, accountUuid: account.accountUuid)
        return status
    }

    /// 用量来自 Claude Code 运行时写入的缓存 `cachedUsageUtilization`（见工单 08）。
    /// 单独解码：缓存格式有问题只影响用量，不影响订阅信息。
    private static func usage(from data: Data, accountUuid: String?) -> UsageAvailability {
        let cache: CachedUsage
        do {
            guard let decoded = try JSONDecoder().decode(UsageRoot.self, from: data).cachedUsageUtilization else {
                return .noData
            }
            cache = decoded
        } catch {
            return .failed("用量缓存格式无法识别")
        }
        // 切换账号后缓存可能还是上一个账号的
        if let accountUuid, let cached = cache.accountUuid, cached != accountUuid {
            return .noData
        }

        let known: [(id: String, window: CachedUsage.Window?, minutes: Int, label: String?)] = [
            ("five_hour", cache.utilization?.fiveHour, 300, nil),
            ("seven_day", cache.utilization?.sevenDay, 10080, nil),
            ("seven_day_opus", cache.utilization?.sevenDayOpus, 10080, "每周（Opus）"),
            ("seven_day_sonnet", cache.utilization?.sevenDaySonnet, 10080, "每周（Sonnet）"),
        ]
        let windows = known.compactMap { item -> UsageWindow? in
            guard let window = item.window, let percent = window.utilization else { return nil }
            return UsageWindow(
                id: item.id, windowMinutes: item.minutes, usedPercent: percent,
                resetsAt: window.resetsAt.flatMap(DateParsing.iso8601), label: item.label)
        }
        guard !windows.isEmpty else { return .noData }
        return .available(Usage(
            windows: windows,
            capturedAt: cache.fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }))
    }

    private func status(from account: OAuthAccount) -> SubscriptionStatus {
        let plan = Self.plan(
            organizationType: account.organizationType,
            seatTier: account.seatTier,
            userRateLimitTier: account.userRateLimitTier)

        var state: SubscriptionStatus.State = plan == nil ? .unknown : .active
        var periodEnd: Date?
        if let trialEnd = account.claudeCodeTrialEndsAt?.date {
            periodEnd = trialEnd
            state = trialEnd > now() ? .trial : .expired
        }

        var details: [Detail] = []
        if let billingType = account.billingType {
            details.append(Detail("billingType", billingType))
        }
        if let tier = account.userRateLimitTier {
            details.append(Detail("userRateLimitTier", tier))
        }
        if let extraUsage = account.hasExtraUsageEnabled {
            details.append(Detail("hasExtraUsageEnabled", String(extraUsage)))
        }

        return SubscriptionStatus(
            plan: plan ?? Plan(rawValue: "", displayName: "未知套餐"),
            state: state,
            account: account.emailAddress,
            organization: account.organizationName,
            periodEnd: periodEnd,
            details: details,
            sourceUpdatedAt: account.profileFetchedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// 由 `organizationType` + `seatTier` 推导套餐，例如 `claude_team` + `team_standard` → “Team · Standard”。
    /// 个人 Max 套餐从 `userRateLimitTier` 里认出倍数（如 `default_claude_max_20x` → “Max 20x”）。
    /// 认不出的部分原样显示；没有 `organizationType` 时返回 nil。
    static func plan(organizationType: String?, seatTier: String?, userRateLimitTier: String?) -> Plan? {
        guard let organizationType else { return nil }

        let names = [
            "claude_free": "Free",
            "claude_pro": "Pro",
            "claude_max": "Max",
            "claude_team": "Team",
            "claude_enterprise": "Enterprise",
        ]
        var displayName = names[organizationType] ?? organizationType

        if organizationType == "claude_max",
           let tier = userRateLimitTier,
           let range = tier.range(of: #"max_(\d+x)$"#, options: .regularExpression) {
            displayName += " " + tier[range].dropFirst("max_".count)
        }

        var rawValue = organizationType
        if let seatTier {
            rawValue += "/" + seatTier
            displayName += " · " + Self.seatName(seatTier)
        }
        return Plan(rawValue: rawValue, displayName: displayName)
    }

    /// `team_standard` / `enterprise_premium` 之类的席位档位；认不出的原样返回。
    private static func seatName(_ seatTier: String) -> String {
        let levels = ["standard": "Standard", "premium": "Premium"]
        for prefix in ["team_", "enterprise_"] where seatTier.hasPrefix(prefix) {
            if let name = levels[String(seatTier.dropFirst(prefix.count))] {
                return name
            }
        }
        return seatTier
    }
}

// MARK: - 文件格式（只建模 `oauthAccount`，其他字段由 JSONDecoder 忽略）

private struct Root: Decodable {
    let oauthAccount: OAuthAccount?
}

private struct OAuthAccount: Decodable {
    let accountUuid: String?
    let emailAddress: String?
    let organizationName: String?
    let organizationType: String?
    let seatTier: String?
    let billingType: String?
    let userRateLimitTier: String?
    let hasExtraUsageEnabled: Bool?
    let claudeCodeTrialEndsAt: FlexibleDate?
    /// 毫秒时间戳。
    let profileFetchedAt: Double?
}

/// 时间字段可能是 ISO 8601 字符串，也可能是毫秒时间戳。
private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: milliseconds / 1000)
        } else if let string = try? container.decode(String.self) {
            date = DateParsing.iso8601(string)
        } else {
            date = nil
        }
    }
}

/// 只建模 `cachedUsageUtilization` 中的已知窗口；其他字段（内部代号、`extra_usage` 等）忽略。
private struct UsageRoot: Decodable {
    let cachedUsageUtilization: CachedUsage?
}

private struct CachedUsage: Decodable {
    let fetchedAtMs: Double?
    let accountUuid: String?
    let utilization: Utilization?

    struct Utilization: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDayOpus: Window?
        let sevenDaySonnet: Window?

        private enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }

        /// 某个窗口格式不对时只忽略这个窗口。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDayOpus = try? container.decodeIfPresent(Window.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? container.decodeIfPresent(Window.self, forKey: .sevenDaySonnet)
        }
    }

    struct Window: Decodable {
        /// 已用比例（%）。
        let utilization: Double?
        let resetsAt: String?

        private enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}
