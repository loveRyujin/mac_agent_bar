import AgentBarCore
import SwiftUI

/// 设置界面。所有改动直接写进 `model.settings`，立即保存并生效。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLogin

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

            Section("提醒") {
                Stepper(value: $model.settings.expiryWarningDays, in: 1...30) {
                    Text("订阅到期前 \(model.settings.expiryWarningDays) 天开始提醒")
                }
                Stepper(value: $model.settings.usageWarningThreshold, in: 50...100, step: 5) {
                    Text("额度用到 \(model.settings.usageWarningThreshold)% 时提醒")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // 用户可能在系统设置里改过登录项，打开设置窗口时重新读取
        .onAppear { launchAtLogin.refreshStatus() }
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
