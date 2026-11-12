import AgentBarCore
import SwiftUI

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    /// 图标被隐藏时应用不退出（见 `MenuBarVisibility`）。
    @AppStorage(MenuBarVisibility.key) private var showInMenuBar = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 状态栏：始终显示 AgentBar 的 logo，旁边的文字由设置中的状态栏样式决定（见 `WarningRules.statusBarText`）。
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            AgentIconView(iconName: "agentbar", displayName: "AgentBar")
            if let text = model.statusBarText {
                Text(text)
            }
        }
    }
}
