import Foundation

/// bundle id 从 `local.agentbar` 换成 `io.github.loveryujin.agentbar` 后，把旧 id 下的偏好搬过来。
///
/// 原因：macOS 26 的控制中心把旧 id 的状态栏图标记成了“隐藏”，且在系统设置里无法改回，
/// 导致应用一启动就退出（见工单 19）。
public enum PreferencesMigration {
    /// 旧的 bundle id（也是旧的 UserDefaults 域）。
    public static let legacyDomain = "local.agentbar"

    /// 要迁移的键。不迁移 `launchAtLoginDefaultApplied`（新 id 需要重新注册登录项），
    /// 也不迁移 `NSStatusItem …`（正是旧 id 的问题所在）。
    static let keys = ["settings", "selectedProviderID", "notificationLedger"]

    /// 新域里还没有任何这些键时，从旧域复制过来。返回是否复制了数据。
    @discardableResult
    public static func migrate(from legacy: UserDefaults, to current: UserDefaults) -> Bool {
        guard keys.allSatisfy({ current.object(forKey: $0) == nil }) else { return false }
        var copied = false
        for key in keys {
            if let value = legacy.object(forKey: key) {
                current.set(value, forKey: key)
                copied = true
            }
        }
        return copied
    }
}
