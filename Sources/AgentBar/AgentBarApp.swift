import AgentBarCore
import SwiftUI

@main
struct AgentBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
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
