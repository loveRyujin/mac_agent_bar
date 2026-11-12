import Foundation

/// 需要提醒用户注意的情况：`short` 用在状态栏，`message` 用在面板的 ⚠︎ 说明行。
public struct Warning: Sendable, Equatable {
    public let short: String
    public let message: String

    public init(short: String, message: String) {
        self.short = short
        self.message = message
    }
}

/// 警示规则：订阅在 7 天内（按日历天数）到期、已过期、读取失败，三者任一即警示。
public struct WarningRules: Sendable {
    public static let warningDays = 7

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func warning(for outcome: Result<SubscriptionStatus, ProviderError>, now: Date) -> Warning? {
        let status: SubscriptionStatus
        switch outcome {
        case .failure(let error):
            return Warning(short: "读取失败", message: error.message)
        case .success(let value):
            status = value
        }

        if status.state == .expired || status.periodEnd.map({ $0 <= now }) == true {
            let message = status.periodEnd.map { "订阅已于 \(formatDate($0, now: now))到期" } ?? "订阅已过期"
            return Warning(short: "已过期", message: message)
        }

        guard let periodEnd = status.periodEnd else { return nil }
        let days = daysUntil(periodEnd, from: now)
        guard days <= Self.warningDays else { return nil }

        let short = switch days {
        case 0: "今天到期"
        case 1: "明天到期"
        default: "\(days) 天后到期"
        }
        let subject = status.state == .trial ? "试用" : "订阅"
        return Warning(
            short: short,
            message: "\(subject)将于 \(formatDate(periodEnd, now: now))到期（\(relativeDays(days))）")
    }

    /// 状态栏文字：有警示时显示警示，否则显示套餐短名称。
    public func statusBarText(for outcome: Result<SubscriptionStatus, ProviderError>, now: Date) -> String {
        if let warning = warning(for: outcome, now: now) { return warning.short }
        guard case .success(let status) = outcome else { return "" }
        return status.plan.shortName
    }

    /// 从 `now` 所在的那天到 `date` 所在的那天相差几天（日历天数，可为负）。
    public func daysUntil(_ date: Date, from now: Date) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// “11 月 22 日”；不在今年时带上年份，“2027 年 1 月 3 日”。
    public func formatDate(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M 月 d 日" : "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    /// 0 → “今天”，1 → “明天”，3 → “3 天后”，-1 → “昨天”，-5 → “5 天前”。
    public func relativeDays(_ days: Int) -> String {
        switch days {
        case 0: "今天"
        case 1: "明天"
        case -1: "昨天"
        case ..<0: "\(-days) 天前"
        default: "\(days) 天后"
        }
    }
}

/// 决定状态栏和面板当前显示哪个 agent。
public enum Selection {
    /// 首选的 agent 已安装且读取成功时选它；否则按注册顺序从它往后（绕回开头）找第一个读取成功的。
    /// 全都失败时，首选已安装就仍选它，否则选第一个已安装的。没有已安装的 agent 时返回 nil。
    public static func resolve(preferred: String?, registryOrder: [String], results: [ProviderResult]) -> String? {
        let installed = results.map(\.provider.id)
        guard let firstInstalled = installed.first else { return nil }

        let succeeded = Set(results.compactMap { result -> String? in
            if case .success = result.outcome { return result.provider.id }
            return nil
        })

        var candidates = registryOrder
        if let preferred, let index = registryOrder.firstIndex(of: preferred) {
            candidates = Array(registryOrder[index...] + registryOrder[..<index])
        }
        if let pick = candidates.first(where: succeeded.contains) {
            return pick
        }
        if let preferred, installed.contains(preferred) {
            return preferred
        }
        return firstInstalled
    }
}
