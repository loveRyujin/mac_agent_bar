import Foundation

/// 套餐：原始值（数据源里的字符串）+ 可读名称。无法识别的套餐，可读名称就是原始值。
public struct Plan: Sendable, Equatable {
    public var rawValue: String
    public var displayName: String
    /// 状态栏里用的短名称（例如 “ChatGPT Plus” → “Plus”），默认与 `displayName` 相同。
    public var shortName: String

    public init(rawValue: String, displayName: String, shortName: String? = nil) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.shortName = shortName ?? displayName
    }

    /// 无法识别的套餐：原样显示原始值。
    public static func unrecognized(_ rawValue: String) -> Plan {
        Plan(rawValue: rawValue, displayName: rawValue)
    }
}

/// 在“详情”里原样展示的额外字段。
public struct Detail: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// 用量/额度，为后续版本预留。第一版恒为 nil。
public struct Usage: Sendable, Equatable {
    public init() {}
}

/// 某个 agent 当前登录账号的订阅信息。
public struct SubscriptionStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case active
        case trial
        case expired
        case signedOut
        case unknown
    }

    public var plan: Plan
    public var state: State
    /// 账号邮箱。
    public var account: String?
    /// 组织名（有的话）。
    public var organization: String?
    /// 到期或下次续费时间。
    public var periodEnd: Date?
    public var details: [Detail]
    /// 数据源自身的更新时间。
    public var sourceUpdatedAt: Date?
    public var usage: Usage?

    public init(
        plan: Plan,
        state: State,
        account: String? = nil,
        organization: String? = nil,
        periodEnd: Date? = nil,
        details: [Detail] = [],
        sourceUpdatedAt: Date? = nil,
        usage: Usage? = nil
    ) {
        self.plan = plan
        self.state = state
        self.account = account
        self.organization = organization
        self.periodEnd = periodEnd
        self.details = details
        self.sourceUpdatedAt = sourceUpdatedAt
        self.usage = usage
    }
}
