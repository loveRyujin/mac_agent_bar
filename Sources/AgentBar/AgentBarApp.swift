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

/// 状态栏：始终显示 AgentBar 的 logo，旁边是选中 agent 的短文字（套餐名或警示）；
/// 其他 agent 有警示时末尾加小圆点。
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            AgentIconView(iconName: "agentbar", displayName: "AgentBar")
            if model.selected != nil {
                Text((model.statusBarText ?? "") + (model.othersHaveWarning ? " •" : ""))
            }
        }
    }
}
