import Foundation

/// 系统通知的类型（spec 第 3 节），每类都可以在设置中单独关闭。
public enum NotificationKind: String, CaseIterable, Sendable, Codable {
    case expiringSoon
    case expired
    case usageHigh
    case usageReset
    case readFailure
}

/// 一条要发出的通知。
public struct NotificationEvent: Sendable, Equatable {
    public let kind: NotificationKind
    /// 点击通知时切换到这个 agent。
    public let providerID: String
    public let title: String
    public let body: String
}

/// 已通知过的事件，用于去重。持久化保存，重启后不会重复通知。
public struct NotificationLedger: Sendable, Equatable, Codable {
    /// 已处理过的事件键，例如 "expired:codex:1795921033"、"usageHigh:claude-code:five_hour:1794469200"。
    var handled: Set<String> = []
    /// 当前处于“连续读取失败”的 agent；恢复正常后移除，下次失败重新通知。
    var failing: Set<String> = []
    /// 通知过“额度快用完”、等待重置的窗口。
    var pendingResets: [PendingReset] = []

    struct PendingReset: Sendable, Equatable, Codable {
        let providerID: String
        let providerName: String
        let windowName: String
        let resetsAt: Date
    }

    public init() {}
}

/// 判断哪些事件需要通知，并更新去重记录。
///
/// 去重：订阅到期类按到期日，额度类按窗口和它的重置时间（即每个周期），读取失败按连续失败。
/// 事件无论通知类型是否被关闭都会记入去重记录，这样重新打开时不会补发旧通知。
public struct NotificationRules: Sendable {
    public var warningRules: WarningRules
    public var disabledKinds: Set<NotificationKind>

    public init(warningRules: WarningRules, disabledKinds: Set<NotificationKind> = []) {
        self.warningRules = warningRules
        self.disabledKinds = disabledKinds
    }

    /// - Parameter results: 本次刷新的结果（被隐藏的 agent 不在其中，因此不会通知）。
    public func evaluate(results: [ProviderResult], ledger: inout NotificationLedger, now: Date) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        func record(_ key: String, _ event: NotificationEvent) {
            guard ledger.handled.insert(key).inserted else { return }
            if !disabledKinds.contains(event.kind) { events.append(event) }
        }

        for result in results {
            let id = result.provider.id
            let name = result.provider.displayName
            let status: SubscriptionStatus
            switch result.outcome {
            case .failure(let error):
                if ledger.failing.insert(id).inserted, !disabledKinds.contains(.readFailure) {
                    events.append(NotificationEvent(
                        kind: .readFailure, providerID: id, title: "\(name) 读取失败", body: error.message))
                }
                continue
            case .success(let value):
                ledger.failing.remove(id)
                status = value
            }

            if let expiry = warningRules.expiryWarning(for: status, now: now) {
                let kind: NotificationKind = expiry.isExpired ? .expired : .expiringSoon
                let end = status.periodEnd.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                record("\(kind.rawValue):\(id):\(end)", NotificationEvent(
                    kind: kind, providerID: id,
                    title: "\(name) \(expiry.isExpired ? "订阅已过期" : "订阅快到期")",
                    body: expiry.warning.message))
            }

            for window in status.usage.usage?.windows ?? [] {
                let effective = window.effective(at: now)
                guard !effective.isInferredReset,
                      effective.usedPercent >= Double(warningRules.usageThreshold)
                else { continue }

                let cycle = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                let key = "\(NotificationKind.usageHigh.rawValue):\(id):\(window.id):\(cycle)"
                guard !ledger.handled.contains(key) else { continue }
                if let resetsAt = window.resetsAt {
                    ledger.pendingResets.append(.init(
                        providerID: id, providerName: name, windowName: window.name, resetsAt: resetsAt))
                }
                let reset = window.resetsAt.map { warningRules.resetText($0, now: now) } ?? "重置时间未知"
                let exhausted = effective.usedPercent >= 100
                record(key, NotificationEvent(
                    kind: .usageHigh, providerID: id,
                    title: "\(name) \(exhausted ? "额度已用完" : "额度快用完")",
                    body: exhausted
                        ? "\(window.name)额度已用完，\(reset)"
                        : "\(window.name)额度已用 \(Int(effective.usedPercent.rounded()))%，\(reset)"))
            }
        }

        // 通知过“快用完”的窗口过了重置时间。只处理本次可见的 agent，被隐藏的先保留。
        let visible = Set(results.map(\.provider.id))
        var stillPending: [NotificationLedger.PendingReset] = []
        for pending in ledger.pendingResets {
            guard visible.contains(pending.providerID), pending.resetsAt <= now else {
                stillPending.append(pending)
                continue
            }
            record(
                "\(NotificationKind.usageReset.rawValue):\(pending.providerID):\(pending.windowName):\(Int(pending.resetsAt.timeIntervalSince1970))",
                NotificationEvent(
                    kind: .usageReset, providerID: pending.providerID,
                    title: "\(pending.providerName) 额度已重置", body: "\(pending.windowName)额度已重置"))
        }
        ledger.pendingResets = stillPending
        return events
    }
}

/// 把去重记录作为 JSON 存进 `UserDefaults`。
public struct NotificationLedgerStore {
    static let key = "notificationLedger"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> NotificationLedger {
        guard let data = defaults.data(forKey: Self.key),
              let ledger = try? JSONDecoder().decode(NotificationLedger.self, from: data)
        else { return NotificationLedger() }
        return ledger
    }

    public func save(_ ledger: NotificationLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
