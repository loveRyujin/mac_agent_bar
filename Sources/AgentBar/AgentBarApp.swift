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

/// 状态栏：选中 agent 的图标 + 短文字（套餐名或警示）；其他 agent 有警示时末尾加小圆点。
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let selected = model.selected {
            HStack(spacing: 4) {
                AgentIconView(iconName: selected.provider.iconName, displayName: selected.provider.displayName)
                Text((model.statusBarText ?? "") + (model.othersHaveWarning ? " •" : ""))
            }
        } else {
            Image(systemName: "person.crop.circle.badge.checkmark")
        }
    }
}
