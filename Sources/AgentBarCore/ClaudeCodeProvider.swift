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
        return status(from: account)
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
