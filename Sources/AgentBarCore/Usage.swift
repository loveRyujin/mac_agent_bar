import Foundation

/// 一个额度窗口（例如 5 小时、每周）在某个时刻的用量。
public struct UsageWindow: Sendable, Equatable {
    /// 数据源里的标识，例如 "primary" / "five_hour"。
    public var id: String
    /// 窗口长度（分钟），用来推出显示名称。
    public var windowMinutes: Int?
    /// 已用比例，0–100。
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(id: String, windowMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// 显示名称：300 → “5 小时”，10080 → “每周”，1440 → “每天”；没有窗口长度时用 `id`。
    public var name: String {
        guard let minutes = windowMinutes else { return id }
        switch minutes {
        case 10080: return "每周"
        case 1440: return "每天"
        case let m where m % 1440 == 0: return "\(m / 1440) 天"
        case let m where m % 60 == 0: return "\(m / 60) 小时"
        default: return "\(minutes) 分钟"
        }
    }

    /// 在 `now` 时刻的实际用量：重置时间已过时，推测为已重置（0%）。
    public func effective(at now: Date) -> EffectiveUsageWindow {
        if let resetsAt, resetsAt <= now {
            return EffectiveUsageWindow(window: self, usedPercent: 0, isInferredReset: true)
        }
        return EffectiveUsageWindow(window: self, usedPercent: usedPercent, isInferredReset: false)
    }
}

/// 考虑了“快照之后已过重置时间”之后的窗口用量。
public struct EffectiveUsageWindow: Sendable, Equatable {
    public let window: UsageWindow
    public let usedPercent: Double
    /// 数据是重置前的快照，重置时间已过，所以推测为 0%。
    public let isInferredReset: Bool
}

/// 某个 agent 的用量：若干额度窗口，以及数据的来源时间。
public struct Usage: Sendable, Equatable {
    public var windows: [UsageWindow]
    /// 数据的来源时间（快照时间）。
    public var capturedAt: Date?

    public init(windows: [UsageWindow], capturedAt: Date?) {
        self.windows = windows
        self.capturedAt = capturedAt
    }

    /// 所有窗口里最高的实际已用比例；没有窗口时为 nil。
    public func highestPercent(at now: Date) -> Double? {
        windows.map { $0.effective(at: now).usedPercent }.max()
    }
}

/// 用量能否拿到。拿不到时只影响用量区，不影响订阅信息。
public enum UsageAvailability: Sendable, Equatable {
    case available(Usage)
    case unsupported
    case networkDisabled
    case noData
    case failed(String)

    public var usage: Usage? {
        if case .available(let usage) = self { return usage }
        return nil
    }

    /// 拿不到用量的原因，显示在用量区；有数据时为 nil。
    public var unavailableReason: String? {
        switch self {
        case .available: nil
        case .unsupported: "暂不支持"
        case .networkDisabled: "未开启联网获取"
        case .noData: "暂无数据"
        case .failed(let reason): "获取失败：\(reason)"
        }
    }
}
