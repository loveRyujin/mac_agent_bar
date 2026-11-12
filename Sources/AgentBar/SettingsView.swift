import AgentBarCore
import SwiftUI

/// 设置界面。所有改动直接写进 `model.settings`，立即保存并生效。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var notifier: Notifier

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: launchAtLoginBinding)
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("需要在“系统设置 → 通用 → 登录项”中允许 AgentBar")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开登录项设置") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Picker("刷新间隔", selection: $model.settings.refreshInterval) {
                    ForEach(AppSettings.RefreshInterval.allCases, id: \.self) { interval in
                        Text("\(interval.minutes) 分钟").tag(interval)
                    }
                }
            }

            Section {
                agentToggles
            } header: {
                Text("显示的 agent")
            } footer: {
                Text("关掉后，该 agent 不读取、不显示，也不提醒。")
                    .foregroundStyle(.secondary)
            }

            Section("显示") {
                Picker("状态栏文字", selection: $model.settings.statusBarStyle) {
                    Text("套餐名").tag(AppSettings.StatusBarStyle.planName)
                    Text("用量百分比").tag(AppSettings.StatusBarStyle.usagePercent)
                    Text("只显示图标").tag(AppSettings.StatusBarStyle.iconOnly)
                }
                Toggle("隐藏邮箱（方便截图）", isOn: $model.settings.hideEmail)
            }

            if model.installedProviders.contains(where: { $0.id == "cursor" }) {
                Section {
                    Toggle("通过 cursor-agent 获取 Cursor 用量", isOn: onlineUsage(of: "cursor"))
                } header: {
                    Text("用量")
                } footer: {
                    Text("会读取钥匙串中 cursor-agent 的登录（需要先安装并运行 cursor-agent login），用它向 api2.cursor.sh 请求用量和续费日。第一次以及每次升级 AgentBar 后，系统会请求钥匙串授权。凭据只在内存中使用，不保存、不刷新。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("提醒") {
                Stepper(value: $model.settings.expiryWarningDays, in: 1...30) {
                    Text("订阅到期前 \(model.settings.expiryWarningDays) 天开始提醒")
                }
                Stepper(value: $model.settings.usageWarningThreshold, in: 50...100, step: 5) {
                    Text("额度用到 \(model.settings.usageWarningThreshold)% 时提醒")
                }
            }

            Section {
                ForEach(NotificationKind.allCases, id: \.self) { kind in
                    Toggle(Self.label(for: kind), isOn: notificationEnabled(kind))
                }
                if notifier.authorizationStatus == .denied {
                    HStack {
                        Text("系统设置中关闭了 AgentBar 的通知").foregroundStyle(.secondary)
                        Spacer()
                        Button("打开通知设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            } header: {
                Text("通知")
            } footer: {
                Text("每个事件只通知一次。第一次需要发通知时会请求通知权限。点击通知会打开面板并切换到对应的 agent。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // 用户可能在系统设置里改过登录项，打开设置窗口时重新读取
        .onAppear {
            launchAtLogin.refreshStatus()
            Task { await notifier.refreshAuthorizationStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
    }

    /// 开关显示系统的实际状态；拨动时直接向系统注册或取消，并记进设置。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
            set: { enabled in
                model.settings.launchAtLogin = enabled
                launchAtLogin.setEnabled(enabled)
            })
    }

    /// 只列出已安装的 agent；关掉后不读取、不显示、不提醒。
    @ViewBuilder
    private var agentToggles: some View {
        let providers = model.installedProviders
        if providers.isEmpty {
            Text("没有发现已安装的 agent").foregroundStyle(.secondary)
        } else {
            ForEach(providers, id: \.id) { provider in
                Toggle(isOn: visibility(of: provider.id)) {
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        AgentIconView(iconName: provider.iconName, displayName: provider.displayName)
                    }
                }
            }
        }
    }

    private static func label(for kind: NotificationKind) -> String {
        switch kind {
        case .expiringSoon: "订阅快到期"
        case .expired: "订阅已过期"
        case .usageHigh: "额度快用完"
        case .usageReset: "额度已重置"
        case .readFailure: "读取失败"
        }
    }

    private func notificationEnabled(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { !model.settings.disabledNotificationKinds.contains(kind) },
            set: { enabled in
                if enabled {
                    model.settings.disabledNotificationKinds.remove(kind)
                } else {
                    model.settings.disabledNotificationKinds.insert(kind)
                }
            })
    }

    private func onlineUsage(of id: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.onlineUsageProviderIDs.contains(id) },
            set: { enabled in
                if enabled {
                    model.settings.onlineUsageProviderIDs.insert(id)
                } else {
                    model.settings.onlineUsageProviderIDs.remove(id)
                }
            })
    }

    private func visibility(of id: String) -> Binding<Bool> {
        Binding(
            get: { !model.settings.hiddenProviderIDs.contains(id) },
            set: { visible in
                if visible {
                    model.settings.hiddenProviderIDs.remove(id)
                } else {
                    model.settings.hiddenProviderIDs.insert(id)
                }
            })
    }
}
