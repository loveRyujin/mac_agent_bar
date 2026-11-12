import AgentBarCore
import Foundation
import ServiceManagement

/// 开机自启（系统登录项，`SMAppService.mainApp`，macOS 13 起可用）。
///
/// 以系统的实际状态为准：用户也可能在“系统设置 → 通用 → 登录项”里直接关掉它，
/// 所以设置中的默认值（开）只在第一次启动时应用一次，之后不再自动改动。
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    /// 最近一次开关失败的原因，显示在设置界面里。
    @Published private(set) var errorMessage: String?

    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    init(defaults: UserDefaults = .standard, settings: AppSettings) {
        status = SMAppService.mainApp.status
        if !defaults.bool(forKey: Self.defaultAppliedKey) {
            defaults.set(true, forKey: Self.defaultAppliedKey)
            if settings.launchAtLogin, status != .enabled {
                setEnabled(true)
            }
        }
    }

    var isEnabled: Bool { status == .enabled }

    /// 已注册，但需要用户在“登录项”里允许。
    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "无法\(enabled ? "开启" : "关闭")开机自启：\(error.localizedDescription)"
        }
        refreshStatus()
    }

    /// 重新读取系统状态（用户可能在系统设置里改过）。
    func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
