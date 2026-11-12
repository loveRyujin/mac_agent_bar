import AgentBarCore
import SwiftUI

/// 设置界面。所有改动直接写进 `model.settings`，立即保存并生效。
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("通用") {
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
                    Text("只显示图标").tag(AppSettings.StatusBarStyle.iconOnly)
                }
                Toggle("隐藏邮箱（方便截图）", isOn: $model.settings.hideEmail)
            }

            Section("提醒") {
                Stepper(value: $model.settings.expiryWarningDays, in: 1...30) {
                    Text("订阅到期前 \(model.settings.expiryWarningDays) 天开始提醒")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
