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

/// 警示规则。以下任一情况都会警示，按严重程度排序：
/// 读取失败 > 已过期 > 额度已用完 > 订阅在 `warningDays` 天内（按日历天数）到期 > 额度达到 `usageThreshold`。
public struct WarningRules: Sendable {
    public var calendar: Calendar
    /// 订阅到期提前几天警示（来自设置）。
    public var warningDays: Int
    /// 额度窗口已用比例达到多少（%）时警示（来自设置）。
    public var usageThreshold: Int

    public init(
        calendar: Calendar = .current,
        warningDays: Int = AppSettings().expiryWarningDays,
        usageThreshold: Int = AppSettings().usageWarningThreshold
    ) {
        self.calendar = calendar
        self.warningDays = warningDays
        self.usageThreshold = usageThreshold
    }

    /// 最严重的一条警示（状态栏用）；没有警示时为 nil。
    public func warning(for outcome: Result<SubscriptionStatus, ProviderError>, now: Date) -> Warning? {
        warnings(for: outcome, now: now).first
    }

    /// 所有警示，按严重程度从高到低排列（面板逐条显示）。
    public func warnings(for outcome: Result<SubscriptionStatus, ProviderError>, now: Date) -> [Warning] {
        let status: SubscriptionStatus
        switch outcome {
        case .failure(let error):
            return [Warning(short: "读取失败", message: error.message)]
        case .success(let value):
            status = value
        }

        let usage = status.usage.usage?.windows.map { $0.effective(at: now) } ?? []
        let exhausted = usage.filter { $0.usedPercent >= 100 }
        let high = usage.filter { $0.usedPercent < 100 && $0.usedPercent >= Double(usageThreshold) }

        var warnings: [Warning] = []
        if let expiry = expiryWarning(for: status, now: now), expiry.isExpired {
            warnings.append(expiry.warning)
        }
        warnings += exhausted.map { window in
            Warning(
                short: "\(window.window.name)已用完",
                message: "\(window.window.name)额度已用完，\(resetSuffix(window.window, now: now))")
        }
        if let expiry = expiryWarning(for: status, now: now), !expiry.isExpired {
            warnings.append(expiry.warning)
        }
        warnings += high.map { window in
            let percent = Int(window.usedPercent.rounded())
            return Warning(
                short: "\(window.window.name) \(percent)%",
                message: "\(window.window.name)额度已用 \(percent)%，\(resetSuffix(window.window, now: now))")
        }
        return warnings
    }

    private func expiryWarning(for status: SubscriptionStatus, now: Date) -> (warning: Warning, isExpired: Bool)? {
        if status.state == .expired || status.periodEnd.map({ $0 <= now }) == true {
            let message = status.periodEnd.map { "订阅已于 \(formatDate($0, now: now))到期" } ?? "订阅已过期"
            return (Warning(short: "已过期", message: message), true)
        }

        guard let periodEnd = status.periodEnd else { return nil }
        let days = daysUntil(periodEnd, from: now)
        guard days <= warningDays else { return nil }

        let short = switch days {
        case 0: "今天到期"
        case 1: "明天到期"
        default: "\(days) 天后到期"
        }
        let subject = status.state == .trial ? "试用" : "订阅"
        return (Warning(
            short: short,
            message: "\(subject)将于 \(formatDate(periodEnd, now: now))到期（\(relativeDays(days))）"), false)
    }

    private func resetSuffix(_ window: UsageWindow, now: Date) -> String {
        window.resetsAt.map { resetText($0, now: now) } ?? "重置时间未知"
    }

    /// 状态栏 logo 旁边的文字；nil 表示只显示 logo。
    /// - 套餐名模式：选中 agent 有警示时显示最严重的警示，否则显示套餐短名称；其他 agent 有警示时末尾加 “ •”。
    /// - 用量百分比模式：同上，但没有警示时显示最高的已用比例（拿不到用量时显示套餐短名称）。
    /// - 只显示图标模式：任何 agent 有警示时显示 “•”。
    /// - Parameter selected: 选中 agent 的结果；没有选中任何 agent 时为 nil。
    public func statusBarText(
        for selected: Result<SubscriptionStatus, ProviderError>?,
        othersHaveWarning: Bool,
        style: AppSettings.StatusBarStyle,
        now: Date
    ) -> String? {
        guard let selected else { return nil }
        let selectedWarning = warning(for: selected, now: now)
        if style == .iconOnly {
            return selectedWarning != nil || othersHaveWarning ? "•" : nil
        }

        var text = selectedWarning?.short ?? ""
        if selectedWarning == nil, case .success(let status) = selected {
            if style == .usagePercent, let percent = status.usage.usage?.highestPercent(at: now) {
                text = "\(Int(percent.rounded()))%"
            } else {
                text = status.plan.shortName
            }
        }
        return othersHaveWarning ? text + " •" : text
    }

    /// 重置时间：24 小时内显示 “2 小时 15 分后重置” / “45 分钟后重置”，更远显示 “11 月 14 日重置”。
    public func resetText(_ resetsAt: Date, now: Date) -> String {
        let minutes = Int(resetsAt.timeIntervalSince(now) / 60)
        switch minutes {
        case ..<1: return "即将重置"
        case ..<60: return "\(minutes) 分钟后重置"
        case ..<(24 * 60):
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours) 小时后重置" : "\(hours) 小时 \(rest) 分后重置"
        default: return "\(formatDate(resetsAt, now: now))重置"
        }
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
