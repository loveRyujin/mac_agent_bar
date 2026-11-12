import Foundation

/// 用户设置。默认值见 spec 第 1 节。
public struct AppSettings: Sendable, Equatable {
    public enum RefreshInterval: Int, CaseIterable, Sendable, Codable {
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30
        case sixtyMinutes = 60

        public var minutes: Int { rawValue }
        public var duration: Duration { .seconds(rawValue * 60) }
    }

    /// 状态栏里 logo 旁边显示什么。
    public enum StatusBarStyle: String, CaseIterable, Sendable, Codable {
        /// 选中 agent 的套餐名（有警示时换成警示文字）
        case planName
        /// 只显示 logo，有警示时加 “•”
        case iconOnly
    }

    public var launchAtLogin = true
    public var refreshInterval = RefreshInterval.fifteenMinutes
    /// 被用户隐藏的 agent：不读取、不显示、不警示。
    public var hiddenProviderIDs: Set<String> = []
    /// 隐藏邮箱（方便截图）。
    public var hideEmail = false
    public var statusBarStyle = StatusBarStyle.planName
    /// 订阅到期提前几天警示。
    public var expiryWarningDays = 7

    public init() {}
}

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, refreshInterval, hiddenProviderIDs, hideEmail, statusBarStyle, expiryWarningDays
    }

    /// 缺失或无法识别的字段各自回退到默认值，不影响其他字段。
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, default fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        launchAtLogin = value(.launchAtLogin, default: launchAtLogin)
        refreshInterval = value(.refreshInterval, default: refreshInterval)
        hiddenProviderIDs = value(.hiddenProviderIDs, default: hiddenProviderIDs)
        hideEmail = value(.hideEmail, default: hideEmail)
        statusBarStyle = value(.statusBarStyle, default: statusBarStyle)
        expiryWarningDays = value(.expiryWarningDays, default: expiryWarningDays)
    }
}

/// 把设置作为一个 JSON 存进 `UserDefaults`。
public struct SettingsStore {
    static let key = "settings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取设置；没有保存过或数据损坏时返回默认值。
    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension SubscriptionStatus {
    /// 把账号、组织名和详情中出现的邮箱替换成 “•••@•••”（用于“隐藏邮箱”）。
    public func redactingEmails() -> SubscriptionStatus {
        func redact(_ text: String) -> String {
            text.replacingOccurrences(
                of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                with: "•••@•••",
                options: .regularExpression)
        }
        var copy = self
        copy.account = account.map(redact)
        copy.organization = organization.map(redact)
        copy.details = details.map { Detail($0.label, redact($0.value)) }
        return copy
    }
}
